#!/usr/bin/env python3
"""
Bar Item Lookup - AI-Powered Product Identification

Uses a 3-model consensus approach to identify bar/restaurant products
from abbreviated POS descriptions:
  1. Claude Sonnet 4.6  - Initial identification
  2. GPT-4o             - Verification / disagreement
  3. Gemini 2.5 Flash   - Arbitration (only when models disagree)

Outputs SQL INSERT statements for [TabX].[ImportStagingAI].

Usage:
    python bar_item_lookup.py --input sampleinput.tsv --output output.sql

Requires .env file with: ANTHROPIC_API_KEY, OPENAI_API_KEY, GOOGLE_API_KEY
"""

import argparse
import csv
from datetime import datetime
import httpx
import json
import logging
import os
import re
import ssl
import sys
import time
import unicodedata
from pathlib import Path
from typing import Optional

try:
    import truststore
    truststore.inject_into_ssl()  # covers Gemini and any other HTTP client
except ImportError:
    truststore = None

try:
    from dotenv import load_dotenv
except ImportError:
    print("ERROR: python-dotenv not installed. Run: pip install python-dotenv")
    sys.exit(1)

try:
    import anthropic
except ImportError:
    print("ERROR: anthropic not installed. Run: pip install anthropic")
    sys.exit(1)

try:
    import openai
except ImportError:
    print("ERROR: openai not installed. Run: pip install openai")
    sys.exit(1)

try:
    from google import genai
    from google.genai import types as genai_types
except ImportError:
    print("ERROR: google-genai not installed. Run: pip install google-genai")
    sys.exit(1)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
CLAUDE_MODEL = "claude-sonnet-4-6"
OPENAI_MODEL = "gpt-4o"
GEMINI_MODEL = "gemini-2.5-flash"

FIELDS = [
    "Brand", "BrandNameShort", "BrandKeywords", "ProductName", "ContainerSizeQty", "ContainerSizeUnit",
    "ContainerType", "ABV", "ProductType", "ProductCategory",
    "Country", "City", "StateProv", "CountryCode", "IsWellKnownMixedDrink", "ProductKeywords",
]

PRODUCT_TYPES = {
    "Beer", "Liquor", "Wine", "Mixed Drink", "Food",
    "Energy Drink", "Non-Alcoholic Drink", "Mixers", "Merch",
    "Water", "RTD / Seltzer", "Garnish", "THC / CBD", "Undefined",
}

CONTAINER_TYPES = {
    "Can", "Draft", "Pitcher", "Bottle", "Bucket", "Shot Glass",
    "Wine Glass", "Beer Glass", "Lowball", "Highball", "Carafe",
    "Part", "Generic Glass", "Undefined",
}

CONTAINER_SIZE_UNITS = {
    "Ounce", "Shot", "Drink", "Each", "Undefined",
}

PRODUCT_CATEGORIES = {
    # Beer
    "Brown Ale", "Dark Ale", "India Pale Ale (IPA)", "Pale Ale", "Strong Ale",
    "Bock", "Dark Lager", "Pilsner and Pale Lager", "Porter/Stout",
    "Specialty Beer", "Wheat Beer", "Wild/Sour Beer",
    # RTD / Seltzer
    "Alcoholic Popsicles", "Flavored Malt Beverage", "Hard Coffee",
    "Hard Iced Tea", "Hard Soda", "Hard Seltzer", "Hard Lemonade",
    "Ready To Drink Cocktails", "Hard Cider", "Perry",
    # Liquor
    "Absinthe", "Aquavit", "Awamori", "Baiju", "Bitters", "Brandy",
    "Cachaca", "Genever", "Non-Flavored Gin", "Flavored Gin",
    "Grain Alcohol", "Grappa", "Liqueurs & Cordials", "Mezcal", "Tequila",
    "Ouzo", "Pisco", "Rum", "Shochu", "Soju", "Sotol",
    "Flavored Vodka", "Non-Flavored Vodka",
    "Bourbon", "Canadian Whisky", "Flavored", "Irish Whiskey",
    "Japanese/Asian Whisky", "Misc Whiskey", "Rye", "Scotch Whisky",
    "Blanco Tequila", "Anejo Tequila", "Reposado Tequila",
    # Wine
    "Rice Wine", "Red Wine", "Rose Wine", "White Wine", "Sparkling Wine",
    # Other
    "Mixed Drink", "Food", "Energy Drink", "Non-Alcoholic Drink",
    "Mixers", "Merchandise", "THC / CBD", "Water", "Seltzer",
    "Garnish", "Undefined", "Other Drink",
}

MAX_RETRIES = 3
RETRY_BASE_DELAY = 2  # seconds

# Pricing in USD per million tokens — verify against provider dashboards before large runs.
PRICING = {
    "claude": {"input": 3.00,  "output": 15.00},  # Sonnet rates
    "openai": {"input": 2.50,  "output": 10.00},
    "gemini": {"input": 0.10,  "output":  0.40},
}

COST_PER_ITEM_LIMIT = 0.06  # USD — abort if running average exceeds this
RATE_LIMIT_RETRY_DELAY = 60  # seconds — used when an API rate-limit (HTTP 429) is detected
BATCH_SIZE = 5              # items sent to each model in a single API call

# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------
def setup_logging(log_file: str) -> logging.Logger:
    logger = logging.getLogger("bar_item_lookup")
    logger.setLevel(logging.DEBUG)

    fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s",
                            datefmt="%Y-%m-%d %H:%M:%S")

    fh = logging.FileHandler(log_file, encoding="utf-8", mode="a")
    fh.setLevel(logging.DEBUG)
    fh.setFormatter(fmt)
    logger.addHandler(fh)

    ch = logging.StreamHandler(sys.stdout)
    ch.setLevel(logging.INFO)
    ch.setFormatter(fmt)
    logger.addHandler(ch)

    return logger

# ---------------------------------------------------------------------------
# Prompt templates
# ---------------------------------------------------------------------------
CLAUDE_SYSTEM_PROMPT = """\
You are an expert at identifying bar and restaurant menu items from abbreviated \
POS (Point of Sale) descriptions. These descriptions are often truncated, \
abbreviated, or use shorthand common in the bar/restaurant industry.

Your task is to interpret each item and provide structured product details. \
Consider that the establishment serves both alcoholic beverages and food.

Common POS abbreviations — always apply these consistently:
- POTW  = Pour of the Week
- HH    = Happy Hour
- DBL / Dbl = Double (2× spirit portion)
- SB    = context-dependent: "Small Batch" when directly modifying a spirit \
(e.g. "SB Bourbon" → Small Batch Bourbon); brand abbreviation when it precedes \
a cocktail or mixed-drink name (e.g. "SB Margarita" → Brand "Southbound", \
ProductName "Southbound Margarita"; "SB Esp Martini" → Brand "Southbound", \
ProductName "Southbound Espresso Martini"). Always resolve a short prefix before \
a cocktail name as a potential brand before assuming it is a serving modifier.
- BT    = "Bottle" (serving descriptor — strip it) in all cases unless the full token \
"Buffalo Trace" appears elsewhere in the description. \
Example: "BT Rose Illana" → strip "BT", Brand "Illana", ProductType "Wine", ProductCategory "Rose Wine". \
Use "Buffalo Trace" as Brand only when the POS text contains "Buffalo Trace" in full or \
another unambiguous Buffalo Trace product name (e.g. "Weller", "Eagle Rare", "Blanton's").
- GG    = Grey Goose
- BiB   = Bottled in Bond
- G&T   = Gin and Tonic
- Marg  = Margarita
- Mart  = Martini
- Esp   = Espresso
- Hib   = Hibiscus
- Repo  = Reposado
- Brbn  = Bourbon
- BTL   = Bottle
- N/A   = Non-Alcoholic
- Bkt / Bucket = Bucket (multi-pack of cans/bottles)
- RB     = Red Bull (e.g. "Tropical RB" → Brand "Red Bull", ProductName "Red Bull Tropical Energy Drink")

Rules:
- If an item is clearly a food item, set ABV to null.
- If you cannot determine a field with reasonable confidence, set it to null.
- For cocktails, Brand refers to the primary spirit brand if specified.
- ProductName should be formatted as: shortened brand name (if known) + product descriptor + \
product category, forming a natural readable catalog name. Expand any abbreviations. \
Strip ALL of the following from ProductName — they describe how/when the item is served, \
not what the product actually is: \
(i) Container/serving words: Pitcher, Pint, Can, Bottle, Glass, Cup, Bucket, Shot, Refill, \
Keg, Draft, BTL, DBL, Double, Single, Triple, Extra, Large, Small, Mini, Tall, Short. \
(ii) Event and promotional words: Pride, Happy Hour, HH, POTW, Pour of the Week, \
Special, Featured, Limited, Weekly, Daily, Tonight, Season, Seasonal, Holiday, Event. \
After stripping these words, use the remaining brand and product clues to identify the \
actual product and look it up — do NOT construct a ProductName from the stripped POS tokens. \
IMPORTANT — bar quality-tier words (Well, Call, Premium, Top Shelf) are NOT stripped: they \
identify the product tier. When a spirit is an unbranded well/call/premium pour, set Brand \
to null and keep the tier word in ProductName. \
Example: "Pride Pitcher Garage" → strip "Pride" (promo), strip "Pitcher" (container), \
remaining clue is "Garage" (brand = Garage Beer Co.) → look up their actual product → \
ProductName "Garage Beer Classic Light Beer". \
Examples: "Dickel BiB POTW" → "Dickel Bottled in Bond Bourbon Whiskey"; \
"Gray Whale G&T POTW" → "Gray Whale Gin & Tonic" (branded — Gray Whale is the gin brand); \
"DBL Casamigos Repo" → "Casamigos Reposado Tequila"; \
"DBL Well Vodka" → Brand null, ProductName "Well Vodka" (strip "DBL" as quantity modifier; \
keep "Well" — it is the tier/product identifier, not a serving word); \
"Breakfast Enchiladas" → "Breakfast Enchiladas" (food items need no category suffix if already clear). \
When Brand is identified (even if the brand name does not appear in the POS description), \
its shortened common name MUST appear at the start of ProductName. \
Example: "Pitcher-Bear Walker" → Brand "Jackalope Brewing Company", \
ProductName "Jackalope Bear Walker Brown Ale" (brand inferred from knowledge, not POS text). \
Only omit the brand prefix when no brand can be identified at all. \
Do NOT fabricate product names: if the item cannot be matched to a verified real-world product \
(spirit brand, brewery, winery, RTD label, etc.), use the expanded description as the \
ProductName without appending speculative category words, and set Brand to null. \
Example: if "Sandpiper" does not match any known spirit or beer brand, return ProductName \
"Sandpiper" (not "Sandpiper Bourbon Whiskey"). A POTW item whose name matches no known \
product is most likely a house cocktail — set ProductType to "Mixed Drink" and Brand to null. \
For ProductType "Mixed Drink", apply these ProductName rules: \
(a) Well-known classic cocktails (Margarita, Old Fashioned, Manhattan, Mojito, Daiquiri, \
French 75, Gin & Tonic, Moscow Mule, Mule, Negroni, Whiskey Sour, Cosmopolitan, \
Aperol Spritz, Espresso Martini, Mimosa, Bloody Mary, Paloma, Gimlet, Sidecar, Spritz, \
Highball, Long Island Iced Tea, Tom Collins, Rum & Coke, Tequila Sunrise, Harvey Wallbanger, \
and similar well-established recipes) with NO specific spirit brand identified must be \
prefixed with "Generic " — e.g., "Generic Margarita", "Generic French 75", \
"Generic Espresso Martini", "Generic Moscow Mule". \
(b) If a specific spirit brand IS identified for a well-known cocktail, use the brand's \
shortened common name as the prefix instead of "Generic " — e.g., "Cuervo Margarita", \
"Gray Whale Gin & Tonic", "Tito's Moscow Mule", "Casamigos Paloma". \
(c) Unique house cocktails or proprietary names that are NOT well-known classic recipes \
(e.g., "Sandpiper", "Baby's First Bourbon", "Kiss From a Rose", "Sunshine Mule") keep \
their name as-is — do NOT prefix with "Generic ". \
(d) A short prefix (1–3 letters) before a well-known cocktail name is more likely a \
brand abbreviation than a serving modifier — always check it against known brands before \
applying "Generic ". If it resolves to a brand, use that brand's name as the prefix \
per rule (b). Example: "SB Margarita" → Brand "Southbound", ProductName \
"Southbound Margarita" (NOT "Generic Margarita"). "SB Esp Martini" → Brand "Southbound", \
ProductName "Southbound Espresso Martini".
For ProductType "Beer", ProductName must always follow the format: \
brewery short name + beer name + beer style suffix — e.g., \
"New Realm Hazy Fox Hazy IPA" (Brand "New Realm Brewing Company"), \
"Jackalope Bear Walker Brown Ale" (Brand "Jackalope Brewing Company"), \
"Lagunitas IPA" (Brand "Lagunitas"), \
"Fat Bottom Brewing Rolling Pin Dunkelweizen" (Brand "Fat Bottom Brewing"). \
When the POS description gives only a partial beer name (e.g., "Hazy Fox", "Fat Bottom", \
"Bear Walker"), use your knowledge of Untappd, brewery websites, and the establishment's \
known tap list to identify the exact product, its full name, its brewery, and its beer style, \
then construct the complete ProductName including all three components (brewery prefix + \
beer name + style suffix). Do NOT return a bare partial name like "Hazy Fox Beer" or \
"Fat Bottom Brewing Beer" when the full catalog name (e.g., "New Realm Hazy Fox Hazy IPA") \
is knowable.
- ContainerSizeQty should be numeric only (e.g., "16", "2"). \
Apply these defaults when the POS description does not specify a size: \
(a) ContainerSizeUnit is "Each", "Drink", or "Shot" → ContainerSizeQty = "1". \
(b) Beer in a Can or Bottle → ContainerSizeQty = "12", ContainerSizeUnit = "Ounce". \
(c) Beer on Draft (tap) → ContainerSizeQty = "16", ContainerSizeUnit = "Ounce". \
(d) Wine (non-sparkling) → ContainerSizeQty = "5", ContainerSizeUnit = "Ounce". \
(e) Sparkling Wine (Champagne, Prosecco, Cava, etc.) → ContainerSizeQty = "4", ContainerSizeUnit = "Ounce". \
(f) Shot Glass → ContainerSizeQty = "1", ContainerSizeUnit = "Shot". \
(g) ProductType is "Liquor" → ContainerSizeQty = "1", ContainerSizeUnit = "Shot", ContainerType = "Shot Glass". \
Only override these defaults when the POS description contains an explicit size (e.g., "16oz", "Pint", "Pitcher").
- ContainerSizeUnit MUST be exactly one of: "Ounce", "Shot", "Drink", "Each", "Undefined". \
Use "Ounce" for oz/ml/cl volume measures. Use "Shot" for a single spirit pour expressed as a count. \
Use "Drink" for a complete mixed drink or cocktail serving. \
Use "Each" for discrete countable items (cans, bottles, food items). \
Use "Undefined" only when the unit truly cannot be determined.
- ContainerType MUST be exactly one of these values (no others are permitted): \
"Can", "Draft", "Pitcher", "Bottle", "Bucket", "Shot Glass", "Wine Glass", \
"Beer Glass", "Lowball", "Highball", "Carafe", "Part", "Generic Glass", "Undefined". \
Use "Draft" for draught/tap beer. Use "Beer Glass" for pints. \
Use "Shot Glass" for shots. Use "Lowball" for rocks/old fashioned glasses. \
Use "Highball" for tall mixed drinks. Use "Wine Glass" for wine. \
Use "Generic Glass" when a glass is indicated but the specific type is unclear. \
Use "Part" for a modifier or add-on (e.g., a splash, side, or extra). \
Use "Undefined" only when the container truly cannot be determined.
- ProductType MUST be exactly one of these values (no others are permitted): \
"Beer", "Liquor", "Wine", "Mixed Drink", "Food", "Energy Drink", \
"Non-Alcoholic Drink", "Mixers", "Merch", "Water", "RTD / Seltzer", \
"Garnish", "THC / CBD", "Undefined". \
Use "Liquor" for all spirits (bourbon, scotch, vodka, tequila, rum, gin, etc.). \
Use "Mixed Drink" for cocktails and shots. \
Use "RTD / Seltzer" for hard seltzers and ready-to-drink canned cocktails. \
Before defaulting to "Mixed Drink", exhaust all specific types using name clues. \
A single beer style word anywhere in the name is sufficient to classify as Beer — \
style words include: "IPA", "Ale", "Lager", "Stout", "Hazy", "Pilsner", "Porter", \
"Pale", "Wheat", "Amber", "Saison", "Sour", "Gose", "Kolsch", "Wit", "Bock", \
"Dunkel", "Pils", "Hefeweizen", "Cider" — e.g., "Hazy Fox" → Beer because "Hazy" \
is a beer style word, even though "Fox" is not. Known brewery names also indicate Beer. \
A single spirit name (bourbon, scotch, vodka, tequila, rum, gin, etc.) suggests Liquor. \
Grape varieties or "Rosé/Blanc/Rouge" suggest Wine. \
For a single-word POS entry that does not match any known cocktail recipe, food item, or \
non-alcoholic beverage: actively check whether the word is a known spirit or liquor brand \
(search your knowledge of distilleries, vodka brands, etc.) before defaulting to "Mixed Drink". \
If it matches a spirit brand, classify as Liquor with ContainerType "Shot Glass", \
ContainerSizeUnit "Shot", ContainerSizeQty "1". \
Only fall back to "Mixed Drink" when no beer style word, spirit name, or wine clue \
is present anywhere in the name after exhausting all available context. \
Use "Undefined" ONLY for items that are clearly not a drink at all (e.g., a tip, room \
rental, cover charge, or POS modifier with no product identity).
- ProductCategory MUST be exactly one of the following values (no others are permitted): \
Beer: "Brown Ale", "Dark Ale", "India Pale Ale (IPA)", "Pale Ale", "Strong Ale", "Bock", \
"Dark Lager", "Pilsner and Pale Lager", "Porter/Stout", "Specialty Beer", "Wheat Beer", \
"Wild/Sour Beer". \
RTD/Seltzer: "Alcoholic Popsicles", "Flavored Malt Beverage", "Hard Coffee", "Hard Iced Tea", \
"Hard Soda", "Hard Seltzer", "Hard Lemonade", "Ready To Drink Cocktails", "Hard Cider", "Perry". \
Liquor: "Absinthe", "Aquavit", "Awamori", "Baiju", "Bitters", "Brandy", "Cachaca", "Genever", \
"Non-Flavored Gin", "Flavored Gin", "Grain Alcohol", "Grappa", "Liqueurs & Cordials", \
"Mezcal", "Tequila", "Ouzo", "Pisco", "Rum", "Shochu", "Soju", "Sotol", \
"Flavored Vodka", "Non-Flavored Vodka", \
"Bourbon", "Canadian Whisky", "Flavored", "Irish Whiskey", "Japanese/Asian Whisky", \
"Misc Whiskey", "Rye", "Scotch Whisky", \
"Blanco Tequila", "Anejo Tequila", "Reposado Tequila". \
Wine: "Rice Wine", "Red Wine", "Rose Wine", "White Wine", "Sparkling Wine". \
Other: "Mixed Drink", "Food", "Energy Drink", "Non-Alcoholic Drink", "Mixers", \
"Merchandise", "THC / CBD", "Water", "Seltzer", "Garnish", "Other Drink", "Undefined". \
Key mappings — always apply: \
IPA/Hazy IPA/Double IPA/Session IPA → "India Pale Ale (IPA)". \
Stout/Porter/Dunkel → "Porter/Stout". \
Hefeweizen/Weizen/Dunkelweizen → "Wheat Beer". \
Mexican Lager/Pale Lager/Märzen → "Pilsner and Pale Lager". \
Sour/Gose/Lambic/Farmhouse → "Wild/Sour Beer". \
Cider → "Hard Cider". Hard seltzer/White Claw/Truly → "Hard Seltzer". \
RTD canned cocktail → "Ready To Drink Cocktails". \
Bourbon/Tennessee Whiskey → "Bourbon". Rye whiskey → "Rye". \
Scotch/Single Malt → "Scotch Whisky". Irish whiskey → "Irish Whiskey". \
Unaged/Silver/Plata tequila → "Blanco Tequila". \
Aged <2mo tequila → "Reposado Tequila". Aged >1yr tequila → "Anejo Tequila". \
Generic/unspecified tequila → "Tequila". \
Plain vodka → "Non-Flavored Vodka". Infused/flavored vodka → "Flavored Vodka". \
Plain gin → "Non-Flavored Gin". Flavored gin → "Flavored Gin". \
Liqueur/cordial/cream liqueur/schnapps → "Liqueurs & Cordials". \
Champagne/Prosecco/Cava/sparkling wine → "Sparkling Wine". Sake → "Rice Wine". \
Rosé/rosado/blush wine → "Rose Wine". \
All cocktails/mixed drinks → "Mixed Drink". All food items → "Food". \
Use "Undefined" only when truly no category fits. Use "Other Drink" for uncategorised beverages.
- Country, City, and StateProv refer to where the product's maker is headquartered \
(the brewery, distillery, winery, or brand owner) — NOT the location of the bar or establishment. \
Examples: Lagunitas → Country "United States", City "Petaluma", StateProv "California"; \
Garage Beer Co. → Country "Spain", City "Barcelona", StateProv null; \
Jack Daniel's → Country "United States", City "Lynchburg", StateProv "Tennessee". \
If a brand name matches both a well-known US product and a lesser-known foreign product, \
prefer the US brand interpretation unless there is clear and specific evidence the item \
is from the foreign brand (e.g., the POS description includes a country, an import label, \
or another unambiguous foreign-brand identifier).
- Draw on your knowledge of bar and restaurant websites, online menus, brand \
websites, and beverage industry resources (distillery sites, brewery sites, \
Untappd, Wine.com, spirits brand pages) to improve accuracy, especially for \
ambiguous or abbreviated items. Use the establishment name and city as context \
to look up its known menu offerings.
- Known brand hints — treat these exactly as specified when encountered: \
"Illana" → Brand "Illana", BrandNameShort "Illana", ProductName "Illana Rose Wine", \
ProductType "Wine", ProductCategory "Rose Wine", ContainerType "Bottle", \
ContainerSizeQty "1", ContainerSizeUnit "Each", Country null, City null, StateProv null. \
Do NOT attempt to resolve "Illana" to any other winery or brand — use "Illana" exactly as-is. \
"Fiyori" → Brand "Fiyori", ProductType "Liquor", ProductCategory "Non-Flavored Vodka", \
ContainerType "Shot Glass", ContainerSizeQty "1", ContainerSizeUnit "Shot".
- IsWellKnownMixedDrink: Applies only when ProductType is "Mixed Drink". \
Return 1 (integer) if the cocktail is well-known across the internet — it has \
published recipes and is served at many different establishments. Examples of \
well-known: Old Fashioned, Margarita, Espresso Martini, White Russian, \
Jagerbomb, Lemon Drop Shot, Collins, French 75, Moscow Mule, Negroni, \
Cosmopolitan, Mojito, Mimosa, Kiss From A Rose. \
Return 0 (integer) if the cocktail appears proprietary or unique to this \
location — its name is invented or not widely found elsewhere \
(e.g., "Sandpiper", "Baby's First Bourbon", "Sunshine Mule"). \
Branded classics still count as well-known ("Cuervo Margarita" → 1, \
"Southbound Margarita" → 1). The "Generic " prefix always implies 1. \
Return null (JSON null, not the string "null") for all ProductTypes \
other than "Mixed Drink".
- ProductKeywords: Words from ProductName that uniquely identify this specific \
product within the Brand's full product catalog. Separate keywords with "|". \
Exclude these stop words: a, an, the, in, on, at, for, of, and, or, but, \
with, to, from, by, is, as, &. Also exclude any word that appears in the names \
of other products in the same Brand's catalog (brand name words appear in all \
products, so always exclude them). Set to null if Brand is null, or if no \
unique keywords remain after exclusions. \
Examples: "Jack Daniel's Tennessee Fire Whiskey" → "Fire" (Jack, Daniel's, \
Tennessee, Whiskey all appear in other JD products). \
"Dickel Bottled in Bond Bourbon Whiskey" → "Bottled|Bond" ("in" is a stop \
word; Dickel, Bourbon, Whiskey appear in other Dickel products). \
"Jackalope Bear Walker Brown Ale" → "Bear|Walker" (Jackalope, Ale appear in \
other Jackalope products; Bear Walker is unique to this beer). \
"New Realm Hazy Fox Hazy IPA" → "Fox" (New Realm, Hazy, IPA appear in other \
New Realm products; Fox uniquely identifies this beer). \
Mixed drink and food ProductNames typically yield null (recipes, not brand \
catalog items — no unique catalog keyword applies).
- BrandNameShort: The Brand name with industry and corporate terms removed. \
Strip leading articles/group words: "The", "Gruppo", "Brouwerij", "Brasserie", "Cerveceria". \
Strip trailing terms iteratively (remove the last word/token if it matches, then repeat \
until no more match): \
Corporate suffixes: "Limited", "Ltd.", "Inc.", "LLC", "Corporation", "Corp.", \
"& Co.", "Co.", "N.V.", "N.V", "S.A.", "S.A", "GmbH", "B.V.", "B.V". \
Industry/operation words: "Brewing Company", "Brewing", "Breweries", "Brewery", \
"Distilling Company", "Distilling", "Distillery", "Distillers", "Winery", "Wines", \
"Vineyards", "Spirits", "Beverages". \
Generic beverage type words: "Beer", "Ale", "Lager", "Wine", "Cellars", "Cellar", \
"Tequila", "Mezcal", "Vodka", "Whiskey", "Whisky", "Rum", "Gin", "Brandy", "Cognac", \
"Liqueur", "Liqueurs", "Liquor", "Cider". \
Keep all remaining words as the short brand name. If nothing would remain after \
stripping, keep the original Brand value unchanged. Set to null when Brand is null. \
Examples: "New Realm Brewing Company" → "New Realm"; \
"Moosehead Breweries Limited" → "Moosehead"; "Hotaling & Co." → "Hotaling"; \
"Bacardi Limited" → "Bacardi"; "Gruppo Campari" → "Campari"; \
"The Macallan Distillers" → "Macallan"; "The Nelson Brothers" → "Nelson Brothers"; \
"Dread River Distilling Company" → "Dread River"; "Grand Marnier" → "Grand Marnier"; \
"Jack Daniel's Distillery" → "Jack Daniel's"; \
"Garage Beer Co." → "Garage"; "Stag's Leap Wine Cellars" → "Stag's Leap"; \
"DeLeon Tequila" → "DeLeon"; "Brouwerij Van Steenberge N.V" → "Van Steenberge".
- BrandKeywords: Pipe-separated words from Brand that uniquely identify this specific brand \
within the beverage industry. Apply the same stop-word exclusion as ProductKeywords \
(a, an, the, in, on, at, for, of, and, or, but, with, to, from, by, is, as, &). \
Also exclude any word that is generically shared across many brand names in the beverage \
industry: Brewing, Brewery, Breweries, Brouwerij, Brasserie, Cerveceria, Cervejaria, \
Distilling, Distillery, Distillers, Winery, Wineries, Wines, Vineyard, Vineyards, \
Spirits, Beverages, Cellars, Cellar, Company, Companies, Co., Ltd., Limited, Inc., \
LLC, Corporation, Corp., Group, N.V., S.A., GmbH, B.V., Beer, Ale, Lager, Wine, \
Cider, Liqueur, Liqueurs, Liquor. \
Set to null if Brand is null, or if no unique keywords remain after exclusions. \
Examples: "Brouwerij Verhaeghe" → "Verhaeghe"; "Cahaba Brewing Company" → "Cahaba"; \
"The Macallan Distillers" → "Macallan"; "Union Wine Company" → "Union"; \
"New Realm Brewing Company" → "New|Realm"; "Jack Daniel's Distillery" → "Jack|Daniel's"; \
"Garage Beer Co." → "Garage"; "Jackalope Brewing Company" → "Jackalope"; \
"Jose Cuervo" → "Jose|Cuervo"; "Lagunitas" → "Lagunitas".
- CountryCode: The ISO 3166-1 Alpha-2 country code corresponding to the Country field. \
Set to null if Country is null. \
Examples: "United States" → "US"; "United Kingdom" → "GB"; "Mexico" → "MX"; \
"France" → "FR"; "Germany" → "DE"; "Spain" → "ES"; "Ireland" → "IE"; \
"Scotland" → "GB" (part of United Kingdom); "Japan" → "JP"; \
"Australia" → "AU"; "Canada" → "CA"; "Italy" → "IT"; \
"Netherlands" → "NL"; "Belgium" → "BE"; "Sweden" → "SE"; "Denmark" → "DK".

Respond with ONLY valid JSON matching this exact structure (no markdown fencing):
{
  "Brand": "string or null",
  "BrandNameShort": "string or null",
  "BrandKeywords": "string or null",
  "ProductName": "string",
  "ContainerSizeQty": "string or null",
  "ContainerSizeUnit": "string or null",
  "ContainerType": "string or null",
  "ABV": "string or null",
  "ProductType": "string",
  "ProductCategory": "string",
  "Country": "string or null",
  "City": "string or null",
  "StateProv": "string or null",
  "CountryCode": "string or null",
  "IsWellKnownMixedDrink": 1 or 0 or null,
  "ProductKeywords": "string or null"
}"""

OPENAI_SYSTEM_PROMPT = """\
You are verifying whether an AI model correctly identified a bar/restaurant POS \
item. Your default answer is AGREE — only set "agrees" to false if there is a \
clear, fundamental identification error. Draw on your knowledge of bar and \
restaurant websites, online menus, brand websites, and beverage industry \
resources (distillery sites, brewery sites, Untappd, Wine.com) to inform your \
verification. Use the establishment name and city as context.

Common POS abbreviations — apply these when evaluating descriptions:
POTW=Pour of the Week, HH=Happy Hour, DBL/Dbl=Double, \
SB=Small Batch (before a spirit, e.g. "SB Bourbon") or Southbound brand \
(before a cocktail name, e.g. "SB Margarita" → Brand "Southbound", \
"SB Esp Martini" → Brand "Southbound"), \
BT="Bottle" (serving descriptor — strip it) in all cases unless the full token \
"Buffalo Trace" appears elsewhere in the description \
(e.g. "BT Rose Illana" → strip "BT", Brand "Illana", ProductType "Wine"; \
use "Buffalo Trace" as Brand only when the POS text contains "Buffalo Trace" in full \
or another unambiguous Buffalo Trace product name such as "Weller", "Eagle Rare", "Blanton's"), \
GG=Grey Goose, BiB=Bottled in Bond, G&T=Gin and Tonic, \
Marg=Margarita, Mart=Martini, Esp=Espresso, Hib=Hibiscus, Repo=Reposado, \
Brbn=Bourbon, BTL=Bottle, N/A=Non-Alcoholic, Bkt/Bucket=Bucket of cans/bottles, \
RB=Red Bull (e.g. "Tropical RB" → Brand "Red Bull", ProductName "Red Bull Tropical Energy Drink").

ProductType must be exactly one of: "Beer", "Liquor", "Wine", "Mixed Drink", \
"Food", "Energy Drink", "Non-Alcoholic Drink", "Mixers", "Merch", "Water", \
"RTD / Seltzer", "Garnish", "THC / CBD", "Undefined". \
ContainerType must be exactly one of: "Can", "Draft", "Pitcher", "Bottle", \
"Bucket", "Shot Glass", "Wine Glass", "Beer Glass", "Lowball", "Highball", \
"Carafe", "Part", "Generic Glass", "Undefined". \
ContainerSizeUnit must be exactly one of: "Ounce", "Shot", "Drink", "Each", "Undefined". \
Apply these ContainerSizeQty defaults when the POS description does not specify a size: \
(a) ContainerSizeUnit is "Each", "Drink", or "Shot" → ContainerSizeQty = "1". \
(b) Beer in a Can or Bottle → ContainerSizeQty = "12", ContainerSizeUnit = "Ounce". \
(c) Beer on Draft (tap) → ContainerSizeQty = "16", ContainerSizeUnit = "Ounce". \
(d) Wine (non-sparkling) → ContainerSizeQty = "5", ContainerSizeUnit = "Ounce". \
(e) Sparkling Wine (Champagne, Prosecco, Cava, etc.) → ContainerSizeQty = "4", ContainerSizeUnit = "Ounce". \
(f) Shot Glass → ContainerSizeQty = "1", ContainerSizeUnit = "Shot". \
(g) ProductType is "Liquor" → ContainerSizeQty = "1", ContainerSizeUnit = "Shot", ContainerType = "Shot Glass". \
Only override these defaults when the POS description contains an explicit size (e.g., "16oz", "Pint", "Pitcher"). \
ProductCategory must be exactly one of: \
Beer: "Brown Ale", "Dark Ale", "India Pale Ale (IPA)", "Pale Ale", "Strong Ale", "Bock", \
"Dark Lager", "Pilsner and Pale Lager", "Porter/Stout", "Specialty Beer", "Wheat Beer", \
"Wild/Sour Beer" — \
RTD: "Alcoholic Popsicles", "Flavored Malt Beverage", "Hard Coffee", "Hard Iced Tea", \
"Hard Soda", "Hard Seltzer", "Hard Lemonade", "Ready To Drink Cocktails", "Hard Cider", "Perry" — \
Liquor: "Absinthe", "Aquavit", "Awamori", "Baiju", "Bitters", "Brandy", "Cachaca", "Genever", \
"Non-Flavored Gin", "Flavored Gin", "Grain Alcohol", "Grappa", "Liqueurs & Cordials", \
"Mezcal", "Tequila", "Ouzo", "Pisco", "Rum", "Shochu", "Soju", "Sotol", \
"Flavored Vodka", "Non-Flavored Vodka", \
"Bourbon", "Canadian Whisky", "Flavored", "Irish Whiskey", "Japanese/Asian Whisky", \
"Misc Whiskey", "Rye", "Scotch Whisky", \
"Blanco Tequila", "Anejo Tequila", "Reposado Tequila" — \
Wine: "Rice Wine", "Red Wine", "Rose Wine", "White Wine", "Sparkling Wine" — \
Other: "Mixed Drink", "Food", "Energy Drink", "Non-Alcoholic Drink", "Mixers", \
"Merchandise", "THC / CBD", "Water", "Seltzer", "Garnish", "Other Drink", "Undefined". \
DISAGREE if ProductType, ContainerType, ContainerSizeUnit, or ProductCategory is not from its respective list. \
DISAGREE if ProductType is "Undefined" for an item that is plausibly a drink — reserve \
"Undefined" only for items clearly not a drink (tip, room rental, cover charge, POS modifier). \
DISAGREE if ProductType is "Mixed Drink" but the item is clearly a more specific type. \
A single beer style word anywhere in the name is sufficient to call it Beer — style words \
include: "IPA", "Ale", "Lager", "Stout", "Hazy", "Pilsner", "Porter", "Pale", "Wheat", \
"Amber", "Saison", "Sour", "Gose", "Kolsch", "Wit", "Bock", "Dunkel", "Pils", \
"Hefeweizen", "Cider" — e.g., "Hazy Fox" → Beer. Known brewery names also indicate Beer. \
A named spirit or spirit brand should be "Liquor". When in doubt between Beer and Mixed \
Drink and a beer style word is present, always choose Beer.

ProductName should be: shortened brand name (if known) + product descriptor + product category. \
When Brand is identified (even if inferred from knowledge rather than present in the POS text), \
its shortened common name MUST be the first word(s) of ProductName. \
Example: "Pitcher-Bear Walker" → Brand "Jackalope Brewing Company", \
ProductName "Jackalope Bear Walker Brown Ale". \
The following must NEVER appear in ProductName — they describe how/when the item is served, \
not what the product is: \
Container/serving words (Pitcher, Pint, Can, Bottle, Glass, Cup, Bucket, Shot, Refill, \
Keg, Draft, BTL, DBL, Double, Single, Triple, Extra, Large, Small, Mini, Tall, Short) and \
event/promotional words (Pride, Happy Hour, HH, POTW, Pour of the Week, Special, Featured, \
Limited, Weekly, Daily, Tonight, Season, Seasonal, Holiday, Event). \
Strip these words from the POS description, then look up the actual product from the \
remaining brand/product clues. \
Example: "Pride Pitcher Garage" → strip "Pride" (promo) and "Pitcher" (container), \
clue = "Garage" → Brand "Garage Beer", ProductName "Garage Beer Classic Light Beer". \
Example: "Dickel BiB POTW" → "Dickel Bottled in Bond Bourbon Whiskey". \
For ProductType "Mixed Drink": well-known classic cocktails (Margarita, Old Fashioned, \
Manhattan, Mojito, Daiquiri, French 75, Gin & Tonic, Moscow Mule, Mule, Negroni, \
Whiskey Sour, Cosmopolitan, Aperol Spritz, Espresso Martini, Mimosa, Bloody Mary, \
Paloma, Gimlet, Sidecar, Spritz, Highball, Long Island Iced Tea, Tom Collins, \
Rum & Coke, Tequila Sunrise, and similar established recipes) with NO specific brand \
must start with "Generic " (e.g., "Generic Margarita", "Generic French 75"). \
If a specific brand IS identified, use the brand short name instead of "Generic " \
(e.g., "Cuervo Margarita", "Gray Whale Gin & Tonic"). \
Unique house cocktails that are not well-known classic recipes keep their name as-is. \
For ProductType "Beer": ProductName must always be in the format \
brewery short name + beer name + beer style suffix — e.g., "New Realm Hazy Fox Hazy IPA", \
"Jackalope Bear Walker Brown Ale", "Lagunitas IPA". \
When only a partial name appears (e.g., "Hazy Fox", "Fat Bottom"), look up the full brewery \
name, beer name, and style using your knowledge of Untappd and brewery websites. \
DISAGREE if ProductName is a raw POS abbreviation rather than a properly expanded catalog name, \
or if it includes serving modifiers like "Double" or "Pour of the Week", \
or if Brand is identified but ProductName does not start with the brand name, \
or if a well-known classic cocktail with no brand is missing the "Generic " prefix, \
or if a well-known classic cocktail with an identified brand uses "Generic " instead of the brand name, \
or if a Beer ProductName omits the identifiable brewery prefix or the beer style suffix \
when the full catalog name is knowable — e.g., "Hazy Fox Beer" or "Fat Bottom Brewing Beer" \
instead of "New Realm Hazy Fox Hazy IPA" or "Fat Bottom Brewing Rolling Pin Dunkelweizen", \
or if ProductName contains container/serving words (Pitcher, Pint, Can, Bottle, Glass, Cup, \
Bucket, Shot, Refill, DBL, Double, etc.) or event/promotional words (Pride, Happy Hour, \
POTW, Special, Featured, etc.) — these must never appear in ProductName, \
or if a well/call/premium spirit item retains a quantity modifier (Double, DBL, Single, \
Triple) in ProductName — e.g., "DBL Well Vodka" must become ProductName "Well Vodka" \
(Brand null; "Well" is the tier/product identifier and must be kept, not stripped).

DISAGREE only if at least one of these is true:
- The brand is flatly wrong (e.g., says "Patron" when the description says "Herradura").
- The product type is completely wrong (e.g., says "Beer" when the item is clearly \
a cocktail, spirit, or food).
- The product is misidentified entirely (e.g., says "food" when the item is clearly \
a bottled spirit).
- ProductName appends fabricated category words (e.g., "Bourbon Whiskey", "Gin") to a \
name that does not correspond to any known real-world product — e.g., "Sandpiper Bourbon \
Whiskey" when no such product exists. In this case, return ProductName as the expanded \
item name only (e.g., "Sandpiper") with Brand null and ProductType "Mixed Drink".

Country, City, and StateProv must reflect where the product's maker is headquartered \
(brewery, distillery, winery, or brand owner) — NOT the location of the bar or establishment. \
DISAGREE if Country/City/StateProv is set to the bar's city/state (e.g., Nashville / Tennessee) \
when the maker is based elsewhere. \
If a brand name matches both a well-known US product and a lesser-known foreign product, \
prefer the US brand interpretation unless the POS description contains a clear foreign-brand \
identifier (e.g., a country name, import label, or unambiguous foreign brand marker). \
DISAGREE if a lesser-known foreign brand was chosen when an equally plausible US brand exists.

For IsWellKnownMixedDrink: DISAGREE if it is not null for non-Mixed Drink items, or if it \
is null for a Mixed Drink item (it must be 0 or 1 for every Mixed Drink). \
DISAGREE if a well-known cocktail (Old Fashioned, Margarita, White Russian, Jagerbomb, \
Lemon Drop Shot, Collins, French 75, Moscow Mule, Negroni, Cosmopolitan, Mojito, Mimosa, \
Kiss From A Rose, Espresso Martini, and similar) is given IsWellKnownMixedDrink=0. \
DISAGREE if an invented/proprietary cocktail name with no findable online recipe is given \
IsWellKnownMixedDrink=1.

For ProductKeywords: DISAGREE if ProductKeywords is non-null when Brand is null. \
DISAGREE if ProductKeywords contains stop words (a, an, the, in, on, at, for, of, and, \
or, but, with, to, from, by, is, as, &) or contains the brand name itself. \
AGREE if ProductKeywords is null for Mixed Drink or Food items (these are recipes, not \
brand catalog entries). Minor keyword differences (e.g., "Fire" vs "Tennessee Fire") \
are NOT grounds for disagreement.
For BrandNameShort: DISAGREE if BrandNameShort is non-null when Brand is null. \
AGREE for any minor difference — BrandNameShort strips leading articles/group words \
("The", "Gruppo", "Brouwerij", "Brasserie") and trailing corporate suffixes \
("Limited", "Inc.", "Co.", "N.V.", "GmbH"), industry words ("Brewing", "Brewery", \
"Distillery", "Winery", "Wines", "Vineyards", "Spirits") and generic beverage type \
words ("Beer", "Wine", "Cellars", "Tequila", "Vodka", "Whiskey", "Rum", "Gin", \
"Liquor", etc.) — minor variations are not grounds for disagreement.
For BrandKeywords: DISAGREE if BrandKeywords is non-null when Brand is null. \
AGREE if BrandKeywords is null when Brand is null. \
Minor keyword differences are NOT grounds for disagreement.
For CountryCode: DISAGREE if CountryCode does not match the ISO 3166-1 Alpha-2 code \
for Country (e.g., "United States" → "US", "United Kingdom" → "GB", "Mexico" → "MX", \
"Scotland" → "GB"). DISAGREE if CountryCode is non-null when Country is null. \
AGREE if CountryCode is null when Country is null.

ALWAYS AGREE for any of the following — these are NOT grounds for disagreement:
- Minor stylistic differences in ProductName (e.g., "Old Fashion" vs "Old Fashioned", \
"Espresso Martini" vs "Espresso Martini Cocktail").
- Missing optional fields (ContainerSizeQty, ABV, Country, City, etc.).
- Minor ProductCategory differences (e.g., "Whiskey Cocktail" vs "Bourbon Cocktail").
- Capitalization or abbreviation style differences.
- Any uncertainty — if you are not sure, AGREE.

When "agrees" is true, copy the previous result exactly into "result" unchanged.

Respond with ONLY valid JSON (no markdown fencing):
{
  "agrees": true/false,
  "result": {
    "Brand": "...", "BrandNameShort": "...", "BrandKeywords": "...", "ProductName": "...", "ContainerSizeQty": "...",
    "ContainerSizeUnit": "...", "ContainerType": "...", "ABV": "...",
    "ProductType": "...", "ProductCategory": "...",
    "Country": "...", "City": "...", "StateProv": "...", "CountryCode": "...",
    "IsWellKnownMixedDrink": 1 or 0 or null,
    "ProductKeywords": "string or null"
  }
}"""

# Few-shot examples for the OpenAI verifier — demonstrate AGREE vs DISAGREE decisions.
# Never mutate this list; ask_openai() uses the + operator to create a new list per call.
OPENAI_FEW_SHOT_MESSAGES = [
    # --- AGREE: correct identification, no grounds for disagreement ---
    {
        "role": "user",
        "content": (
            "Establishment: Martha My Dear (Nashville)\n"
            "Original POS item description: Dickel BiB POTW\n\n"
            'Previous model\'s interpretation:\n'
            '{\n'
            '  "Brand": "Dickel",\n'
            '  "BrandNameShort": "Dickel",\n'
            '  "BrandKeywords": "Dickel",\n'
            '  "ProductName": "Dickel Bottled in Bond Bourbon Whiskey",\n'
            '  "ContainerSizeQty": null,\n'
            '  "ContainerSizeUnit": "Shot",\n'
            '  "ContainerType": "Shot Glass",\n'
            '  "ABV": "45%",\n'
            '  "ProductType": "Liquor",\n'
            '  "ProductCategory": "Bourbon",\n'
            '  "Country": "United States",\n'
            '  "City": "Tullahoma",\n'
            '  "StateProv": "Tennessee",\n'
            '  "CountryCode": "US",\n'
            '  "IsWellKnownMixedDrink": null,\n'
            '  "ProductKeywords": "Bottled|Bond"\n'
            '}'
        ),
    },
    {
        "role": "assistant",
        "content": (
            '{"agrees":true,"result":{"Brand":"Dickel","BrandNameShort":"Dickel","BrandKeywords":"Dickel","ProductName":"Dickel Bottled in Bond Bourbon Whiskey",'
            '"ContainerSizeQty":null,"ContainerSizeUnit":"Shot","ContainerType":"Shot Glass",'
            '"ABV":"45%","ProductType":"Liquor","ProductCategory":"Bourbon",'
            '"Country":"United States","City":"Tullahoma","StateProv":"Tennessee","CountryCode":"US",'
            '"IsWellKnownMixedDrink":null,"ProductKeywords":"Bottled|Bond"}}'
        ),
    },
    # --- AGREE: food item correctly identified ---
    {
        "role": "user",
        "content": (
            "Establishment: Live Oak (Nashville)\n"
            "Original POS item description: No Pickle\n\n"
            'Previous model\'s interpretation:\n'
            '{\n'
            '  "Brand": null,\n'
            '  "BrandNameShort": null,\n'
            '  "BrandKeywords": null,\n'
            '  "ProductName": "No Pickle",\n'
            '  "ContainerSizeQty": null,\n'
            '  "ContainerSizeUnit": "Each",\n'
            '  "ContainerType": "Part",\n'
            '  "ABV": null,\n'
            '  "ProductType": "Food",\n'
            '  "ProductCategory": "Food",\n'
            '  "Country": null,\n'
            '  "City": null,\n'
            '  "StateProv": null,\n'
            '  "CountryCode": null,\n'
            '  "IsWellKnownMixedDrink": null,\n'
            '  "ProductKeywords": null\n'
            '}'
        ),
    },
    {
        "role": "assistant",
        "content": (
            '{"agrees":true,"result":{"Brand":null,"BrandNameShort":null,"BrandKeywords":null,"ProductName":"No Pickle",'
            '"ContainerSizeQty":null,"ContainerSizeUnit":"Each","ContainerType":"Part",'
            '"ABV":null,"ProductType":"Food","ProductCategory":"Food",'
            '"Country":null,"City":null,"StateProv":null,"CountryCode":null,'
            '"IsWellKnownMixedDrink":null,"ProductKeywords":null}}'
        ),
    },
    # --- AGREE: short prefix correctly resolved as brand, not "Generic" ---
    {
        "role": "user",
        "content": (
            "Establishment: Martha My Dear (Nashville)\n"
            "Original POS item description: SB Margarita\n\n"
            'Previous model\'s interpretation:\n'
            '{\n'
            '  "Brand": "Southbound",\n'
            '  "BrandNameShort": "Southbound",\n'
            '  "BrandKeywords": "Southbound",\n'
            '  "ProductName": "Southbound Margarita",\n'
            '  "ContainerSizeQty": null,\n'
            '  "ContainerSizeUnit": "Drink",\n'
            '  "ContainerType": "Highball",\n'
            '  "ABV": null,\n'
            '  "ProductType": "Mixed Drink",\n'
            '  "ProductCategory": "Mixed Drink",\n'
            '  "Country": null,\n'
            '  "City": null,\n'
            '  "StateProv": null,\n'
            '  "CountryCode": null,\n'
            '  "IsWellKnownMixedDrink": 1,\n'
            '  "ProductKeywords": null\n'
            '}'
        ),
    },
    {
        "role": "assistant",
        "content": (
            '{"agrees":true,"result":{"Brand":"Southbound","BrandNameShort":"Southbound","BrandKeywords":"Southbound","ProductName":"Southbound Margarita",'
            '"ContainerSizeQty":null,"ContainerSizeUnit":"Drink","ContainerType":"Highball",'
            '"ABV":null,"ProductType":"Mixed Drink","ProductCategory":"Mixed Drink",'
            '"Country":null,"City":null,"StateProv":null,"CountryCode":null,'
            '"IsWellKnownMixedDrink":1,"ProductKeywords":null}}'
        ),
    },
    # --- DISAGREE: quantity modifier retained in well-spirit ProductName ---
    {
        "role": "user",
        "content": (
            "Establishment: Live Oak (Nashville)\n"
            "Original POS item description: DBL Well Vodka\n\n"
            'Previous model\'s interpretation:\n'
            '{\n'
            '  "Brand": null,\n'
            '  "BrandNameShort": null,\n'
            '  "BrandKeywords": null,\n'
            '  "ProductName": "Double Well Vodka",\n'
            '  "ContainerSizeQty": null,\n'
            '  "ContainerSizeUnit": "Shot",\n'
            '  "ContainerType": "Shot Glass",\n'
            '  "ABV": null,\n'
            '  "ProductType": "Liquor",\n'
            '  "ProductCategory": "Non-Flavored Vodka",\n'
            '  "Country": null,\n'
            '  "City": null,\n'
            '  "StateProv": null,\n'
            '  "CountryCode": null,\n'
            '  "IsWellKnownMixedDrink": null,\n'
            '  "ProductKeywords": null\n'
            '}'
        ),
    },
    {
        "role": "assistant",
        "content": (
            '{"agrees":false,"result":{"Brand":null,"BrandNameShort":null,"BrandKeywords":null,"ProductName":"Well Vodka",'
            '"ContainerSizeQty":null,"ContainerSizeUnit":"Shot","ContainerType":"Shot Glass",'
            '"ABV":null,"ProductType":"Liquor","ProductCategory":"Non-Flavored Vodka",'
            '"Country":null,"City":null,"StateProv":null,"CountryCode":null,'
            '"IsWellKnownMixedDrink":null,"ProductKeywords":null}}'
        ),
    },
    # --- DISAGREE: Beer ProductName missing brewery prefix and style suffix ---
    {
        "role": "user",
        "content": (
            "Establishment: Golden Pony (Nashville)\n"
            "Original POS item description: Hazy Fox\n\n"
            'Previous model\'s interpretation:\n'
            '{\n'
            '  "Brand": null,\n'
            '  "BrandNameShort": null,\n'
            '  "BrandKeywords": null,\n'
            '  "ProductName": "Hazy Fox Beer",\n'
            '  "ContainerSizeQty": null,\n'
            '  "ContainerSizeUnit": "Ounce",\n'
            '  "ContainerType": "Beer Glass",\n'
            '  "ABV": "6.5%",\n'
            '  "ProductType": "Beer",\n'
            '  "ProductCategory": "India Pale Ale (IPA)",\n'
            '  "Country": "United States",\n'
            '  "City": "Atlanta",\n'
            '  "StateProv": "Georgia",\n'
            '  "CountryCode": "US",\n'
            '  "IsWellKnownMixedDrink": null,\n'
            '  "ProductKeywords": null\n'
            '}'
        ),
    },
    {
        "role": "assistant",
        "content": (
            '{"agrees":false,"result":{"Brand":"New Realm Brewing Company","BrandNameShort":"New Realm","BrandKeywords":"New|Realm",'
            '"ProductName":"New Realm Hazy Fox Hazy IPA",'
            '"ContainerSizeQty":null,"ContainerSizeUnit":"Ounce","ContainerType":"Beer Glass",'
            '"ABV":"6.5%","ProductType":"Beer","ProductCategory":"India Pale Ale (IPA)",'
            '"Country":"United States","City":"Atlanta","StateProv":"Georgia","CountryCode":"US",'
            '"IsWellKnownMixedDrink":null,"ProductKeywords":"Fox"}}'
        ),
    },
]

GEMINI_SYSTEM_PROMPT = """\
You are an expert arbitrator for identifying bar and restaurant menu items. \
Two AI models have provided different interpretations of a POS description. \
Your job is to decide which interpretation is more accurate, or combine the \
best parts of both. Draw on your knowledge of bar and restaurant websites, \
online menus, brand websites, and beverage industry resources (distillery \
sites, brewery sites, Untappd, Wine.com) to inform your decision. Use the \
establishment name and city as context.

Common POS abbreviations — apply these when evaluating descriptions:
POTW=Pour of the Week, HH=Happy Hour, DBL/Dbl=Double, \
SB=Small Batch (before a spirit, e.g. "SB Bourbon") or Southbound brand \
(before a cocktail name, e.g. "SB Margarita" → Brand "Southbound", \
"SB Esp Martini" → Brand "Southbound"), \
BT="Bottle" (serving descriptor — strip it) in all cases unless the full token \
"Buffalo Trace" appears elsewhere in the description \
(e.g. "BT Rose Illana" → strip "BT", Brand "Illana", ProductType "Wine"; \
use "Buffalo Trace" as Brand only when the POS text contains "Buffalo Trace" in full \
or another unambiguous Buffalo Trace product name such as "Weller", "Eagle Rare", "Blanton's"), \
GG=Grey Goose, BiB=Bottled in Bond, G&T=Gin and Tonic, \
Marg=Margarita, Mart=Martini, Esp=Espresso, Hib=Hibiscus, Repo=Reposado, \
Brbn=Bourbon, BTL=Bottle, N/A=Non-Alcoholic, Bkt/Bucket=Bucket of cans/bottles, \
RB=Red Bull (e.g. "Tropical RB" → Brand "Red Bull", ProductName "Red Bull Tropical Energy Drink").

ProductType in your result must be exactly one of: "Beer", "Liquor", "Wine", \
"Mixed Drink", "Food", "Energy Drink", "Non-Alcoholic Drink", "Mixers", \
"Merch", "Water", "RTD / Seltzer", "Garnish", "THC / CBD", "Undefined". \
ContainerType in your result must be exactly one of: "Can", "Draft", "Pitcher", \
"Bottle", "Bucket", "Shot Glass", "Wine Glass", "Beer Glass", "Lowball", \
"Highball", "Carafe", "Part", "Generic Glass", "Undefined". \
ContainerSizeUnit in your result must be exactly one of: \
"Ounce", "Shot", "Drink", "Each", "Undefined". \
Apply these ContainerSizeQty defaults when the POS description does not specify a size: \
(a) ContainerSizeUnit is "Each", "Drink", or "Shot" → ContainerSizeQty = "1". \
(b) Beer in a Can or Bottle → ContainerSizeQty = "12", ContainerSizeUnit = "Ounce". \
(c) Beer on Draft (tap) → ContainerSizeQty = "16", ContainerSizeUnit = "Ounce". \
(d) Wine (non-sparkling) → ContainerSizeQty = "5", ContainerSizeUnit = "Ounce". \
(e) Sparkling Wine (Champagne, Prosecco, Cava, etc.) → ContainerSizeQty = "4", ContainerSizeUnit = "Ounce". \
(f) Shot Glass → ContainerSizeQty = "1", ContainerSizeUnit = "Shot". \
(g) ProductType is "Liquor" → ContainerSizeQty = "1", ContainerSizeUnit = "Shot", ContainerType = "Shot Glass". \
Only override these defaults when the POS description contains an explicit size (e.g., "16oz", "Pint", "Pitcher"). \
ProductCategory in your result must be exactly one of: \
Beer: "Brown Ale", "Dark Ale", "India Pale Ale (IPA)", "Pale Ale", "Strong Ale", "Bock", \
"Dark Lager", "Pilsner and Pale Lager", "Porter/Stout", "Specialty Beer", "Wheat Beer", \
"Wild/Sour Beer" — \
RTD: "Alcoholic Popsicles", "Flavored Malt Beverage", "Hard Coffee", "Hard Iced Tea", \
"Hard Soda", "Hard Seltzer", "Hard Lemonade", "Ready To Drink Cocktails", "Hard Cider", "Perry" — \
Liquor: "Absinthe", "Aquavit", "Awamori", "Baiju", "Bitters", "Brandy", "Cachaca", "Genever", \
"Non-Flavored Gin", "Flavored Gin", "Grain Alcohol", "Grappa", "Liqueurs & Cordials", \
"Mezcal", "Tequila", "Ouzo", "Pisco", "Rum", "Shochu", "Soju", "Sotol", \
"Flavored Vodka", "Non-Flavored Vodka", \
"Bourbon", "Canadian Whisky", "Flavored", "Irish Whiskey", "Japanese/Asian Whisky", \
"Misc Whiskey", "Rye", "Scotch Whisky", \
"Blanco Tequila", "Anejo Tequila", "Reposado Tequila" — \
Wine: "Rice Wine", "Red Wine", "Rose Wine", "White Wine", "Sparkling Wine" — \
Other: "Mixed Drink", "Food", "Energy Drink", "Non-Alcoholic Drink", "Mixers", \
"Merchandise", "THC / CBD", "Water", "Seltzer", "Garnish", "Other Drink", "Undefined". \
Prefer the interpretation whose ProductType, ContainerType, ContainerSizeUnit, and ProductCategory are from these lists. \
When choosing or combining, prefer a specific ProductType (Beer, Liquor, Wine, etc.) over \
"Mixed Drink" whenever one model has identified the type with good supporting evidence. \
A single beer style word anywhere in the name ("Hazy", "IPA", "Ale", "Lager", "Stout", \
"Pilsner", "Porter", "Pale", "Wheat", "Amber", "Saison", "Sour", "Cider", etc.) is \
sufficient evidence to prefer Beer over Mixed Drink — e.g., "Hazy Fox" → Beer. \
If one model says "Beer" and the other says "Mixed Drink", always choose Beer unless \
there is explicit evidence the item is a cocktail (e.g., contains a cocktail name like \
"Martini", "Daiquiri", "Mule", "Margarita"). \
Prefer "Mixed Drink" over "Undefined" only when the item is clearly a drink but genuinely \
cannot be typed more specifically. \
Use "Undefined" only for items clearly not a drink at all (tip, room rental, cover charge).

ProductName in your result should be: shortened brand name (if known) + product descriptor + \
product category. When Brand is identified (even if inferred from knowledge rather than present \
in the POS text), its shortened common name MUST be the first word(s) of ProductName. \
Example: "Pitcher-Bear Walker" → Brand "Jackalope Brewing Company", \
ProductName "Jackalope Bear Walker Brown Ale". \
The following must NEVER appear in ProductName: \
container/serving words (Pitcher, Pint, Can, Bottle, Glass, Cup, Bucket, Shot, Refill, \
Keg, Draft, BTL, DBL, Double, Single, Triple, Extra, Large, Small) and \
event/promotional words (Pride, Happy Hour, HH, POTW, Pour of the Week, Special, Featured, \
Limited, Weekly, Daily, Tonight, Season, Seasonal, Holiday, Event). \
Strip these from the POS tokens, then identify the actual product from the remaining clues. \
IMPORTANT — bar quality-tier words (Well, Call, Premium, Top Shelf) are NOT stripped: \
they identify the product tier. When a spirit is an unbranded well/call/premium pour, \
Brand must be null and the tier word must remain in ProductName. \
Example: "Pride Pitcher Garage" → strip "Pride"+"Pitcher" → Brand "Garage Beer", \
ProductName "Garage Beer Classic Light Beer". \
Example: "Dickel BiB POTW" → "Dickel Bottled in Bond Bourbon Whiskey". \
Example: "DBL Well Vodka" → Brand null, ProductName "Well Vodka" (strip "DBL"; keep "Well"). \
For ProductType "Mixed Drink": well-known classic cocktails (Margarita, Old Fashioned, \
Manhattan, Mojito, Daiquiri, French 75, Gin & Tonic, Moscow Mule, Mule, Negroni, \
Whiskey Sour, Cosmopolitan, Aperol Spritz, Espresso Martini, Mimosa, Bloody Mary, \
Paloma, Gimlet, Sidecar, Spritz, Highball, Long Island Iced Tea, Tom Collins, \
Rum & Coke, Tequila Sunrise, and similar established recipes) with NO brand must start \
with "Generic " (e.g., "Generic Margarita", "Generic French 75"). If a brand IS identified, \
use the brand short name instead (e.g., "Cuervo Margarita"). \
Unique house cocktail names that are not well-known recipes keep their name as-is. \
For ProductType "Beer": ProductName must always be in the format \
brewery short name + beer name + beer style suffix — e.g., "New Realm Hazy Fox Hazy IPA", \
"Jackalope Bear Walker Brown Ale", "Lagunitas IPA". \
When only a partial name appears (e.g., "Hazy Fox", "Fat Bottom"), resolve it to the full \
brewery name, beer name, and style using Untappd knowledge and brewery websites. \
Prefer the interpretation with the more complete beer ProductName \
(brewery prefix + beer name + style suffix) over a bare partial name. \
Prefer the interpretation whose ProductName starts with the brand name (when a brand is known) \
and is a properly expanded catalog name with no serving modifiers and correct "Generic " prefix.

Rules:
- Country, City, and StateProv must reflect where the product's maker is headquartered \
(brewery, distillery, winery, or brand owner) — NOT the location of the bar or establishment. \
Prefer the interpretation whose Country/City/StateProv reflects the maker's HQ, not the bar's city. \
If a brand name matches both a well-known US product and a lesser-known foreign product, \
prefer the US brand interpretation unless the POS description contains a clear foreign-brand \
identifier (e.g., a country name, import label, or unambiguous foreign brand marker).
- Evaluate both interpretations against the original POS description.
- Pick the one that is most likely correct, or create a combined answer.
- Do NOT fabricate product names. If neither model can match the item to a verified \
real-world product, prefer (or create) an answer that uses the expanded item name as-is \
without appended category words, sets Brand to null, and uses ProductType "Mixed Drink" \
for ambiguous bar items (e.g., unrecognised POTW cocktail names).
- Set "winner" to "A" if Model A (Claude) is correct, "B" if Model B (OpenAI) \
is correct, or "combined" if you merged the best of both.
- IsWellKnownMixedDrink: In your result, set to 1 (integer) if ProductType is \
"Mixed Drink" and the cocktail is well-known across the internet (has published recipes, \
served at many venues — e.g., Old Fashioned, Margarita, Espresso Martini, White Russian, \
Jagerbomb, Lemon Drop Shot, Collins, Kiss From A Rose). Set to 0 (integer) if the \
cocktail is proprietary or has no widely findable recipe. Set to null for all \
ProductTypes other than "Mixed Drink". Prefer the interpretation with the correct \
integer (not null) for Mixed Drink items.
- ProductKeywords: In your result, include pipe-separated words from ProductName that \
uniquely identify this product within the Brand's catalog, after excluding stop words \
(a, an, the, in, on, at, for, of, and, or, but, with, to, from, by, is, as, &) and \
words shared across other products in the same brand's portfolio. Set to null if Brand \
is null or no unique keywords remain. Prefer the interpretation with the more precise \
and complete ProductKeywords. Mixed Drink and Food items typically yield null.
- BrandKeywords: In your result, include pipe-separated words from Brand that uniquely \
identify the brand within the beverage industry, after excluding stop words and words \
generically shared across brand names (Brewing, Brewery, Distillery, Distillers, Winery, \
Wines, Vineyards, Spirits, Beverages, Cellars, Cellar, Company, Co., Ltd., Limited, Inc., \
LLC, Corporation, Corp., Group, N.V., S.A., GmbH, B.V., Brouwerij, Brasserie, Cerveceria, \
Beer, Ale, Lager, Wine, Cider, Liqueur, Liqueurs, Liquor). \
Set to null if Brand is null. Prefer the interpretation with the correct BrandKeywords.
- CountryCode: In your result, set to the ISO 3166-1 Alpha-2 code for Country \
("United States" → "US", "United Kingdom" → "GB", "Mexico" → "MX", "France" → "FR", \
"Germany" → "DE", "Spain" → "ES", "Ireland" → "IE", "Scotland" → "GB", \
"Japan" → "JP", "Australia" → "AU", "Canada" → "CA", "Italy" → "IT", \
"Netherlands" → "NL", "Belgium" → "BE"). Set to null if Country is null. \
Prefer the interpretation with the correct CountryCode.

Respond with ONLY valid JSON (no markdown fencing):
{
  "winner": "A" or "B" or "combined",
  "result": {
    "Brand": "...", "BrandNameShort": "...", "BrandKeywords": "...", "ProductName": "...", "ContainerSizeQty": "...",
    "ContainerSizeUnit": "...", "ContainerType": "...", "ABV": "...",
    "ProductType": "...", "ProductCategory": "...",
    "Country": "...", "City": "...", "StateProv": "...", "CountryCode": "...",
    "IsWellKnownMixedDrink": 1 or 0 or null,
    "ProductKeywords": "string or null"
  }
}"""

# Batch variant of the Gemini arbitration prompt — identical rules but instructs Gemini
# to return a JSON *array* (one object per item) instead of a single object.
# Derived from GEMINI_SYSTEM_PROMPT so the shared rules stay in sync automatically.
_GEMINI_ARBITRATION_BASE, _ = GEMINI_SYSTEM_PROMPT.rsplit("Respond with ONLY", 1)
GEMINI_BATCH_ARBITRATION_SYSTEM_PROMPT = _GEMINI_ARBITRATION_BASE + """\
You will receive multiple items. Respond with ONLY valid JSON — a JSON array \
with one object per item, in the same order as the items (no markdown fencing):
[
  {
    "winner": "A" or "B" or "combined",
    "result": {
      "Brand": "...", "BrandNameShort": "...", "BrandKeywords": "...", "ProductName": "...", "ContainerSizeQty": "...",
      "ContainerSizeUnit": "...", "ContainerType": "...", "ABV": "...",
      "ProductType": "...", "ProductCategory": "...",
      "Country": "...", "City": "...", "StateProv": "...", "CountryCode": "...",
      "IsWellKnownMixedDrink": 1 or 0 or null,
      "ProductKeywords": "string or null"
    }
  }
]"""

# Few-shot examples for Claude — user/assistant message pairs.
# Never mutate this list; ask_claude() uses the + operator to create a new list per call.
CLAUDE_FEW_SHOT_MESSAGES = [
    {
        "role": "user",
        "content": "Establishment: Martha My Dear (Nashville)\nIdentify this bar/restaurant POS item:\n\nDickel BiB POTW",
    },
    {
        "role": "assistant",
        "content": '{"Brand":"Dickel","BrandNameShort":"Dickel","BrandKeywords":"Dickel","ProductName":"Dickel Bottled in Bond Bourbon Whiskey","ContainerSizeQty":null,"ContainerSizeUnit":"Shot","ContainerType":"Shot Glass","ABV":"45%","ProductType":"Liquor","ProductCategory":"Bourbon","Country":"United States","City":"Tullahoma","StateProv":"Tennessee","CountryCode":"US","IsWellKnownMixedDrink":null,"ProductKeywords":"Bottled|Bond"}',
    },
    {
        "role": "user",
        "content": "Establishment: Frankie J's (Nashville)\nIdentify this bar/restaurant POS item:\n\nDBL Hendrick's",
    },
    {
        "role": "assistant",
        "content": '{"Brand":"Hendrick\'s","BrandNameShort":"Hendrick\'s","BrandKeywords":"Hendrick\'s","ProductName":"Hendrick\'s Gin","ContainerSizeQty":"2","ContainerSizeUnit":"Shot","ContainerType":"Shot Glass","ABV":"41.4%","ProductType":"Liquor","ProductCategory":"Non-Flavored Gin","Country":"United Kingdom","City":"Girvan","StateProv":"Scotland","CountryCode":"GB","IsWellKnownMixedDrink":null,"ProductKeywords":null}',
    },
    {
        "role": "user",
        "content": "Establishment: Live Oak (Nashville)\nIdentify this bar/restaurant POS item:\n\nNo Pickle",
    },
    {
        "role": "assistant",
        "content": '{"Brand":null,"BrandNameShort":null,"BrandKeywords":null,"ProductName":"No Pickle","ContainerSizeQty":null,"ContainerSizeUnit":"Each","ContainerType":"Part","ABV":null,"ProductType":"Food","ProductCategory":"Food","Country":null,"City":null,"StateProv":null,"CountryCode":null,"IsWellKnownMixedDrink":null,"ProductKeywords":null}',
    },
    {
        "role": "user",
        "content": "Establishment: Live Oak (Nashville)\nIdentify this bar/restaurant POS item:\n\nPitcher-Lagunitas IPA",
    },
    {
        "role": "assistant",
        "content": '{"Brand":"Lagunitas","BrandNameShort":"Lagunitas","BrandKeywords":"Lagunitas","ProductName":"Lagunitas IPA","ContainerSizeQty":"60","ContainerSizeUnit":"Ounce","ContainerType":"Pitcher","ABV":"6.2%","ProductType":"Beer","ProductCategory":"India Pale Ale (IPA)","Country":"United States","City":"Petaluma","StateProv":"California","CountryCode":"US","IsWellKnownMixedDrink":null,"ProductKeywords":null}',
    },
    {
        "role": "user",
        "content": "Establishment: Live Oak (Nashville)\nIdentify this bar/restaurant POS item:\n\nPitcher-Bear Walker",
    },
    {
        "role": "assistant",
        "content": '{"Brand":"Jackalope Brewing Company","BrandNameShort":"Jackalope","BrandKeywords":"Jackalope","ProductName":"Jackalope Bear Walker Brown Ale","ContainerSizeQty":"60","ContainerSizeUnit":"Ounce","ContainerType":"Pitcher","ABV":"5.3%","ProductType":"Beer","ProductCategory":"Brown Ale","Country":"United States","City":"Nashville","StateProv":"Tennessee","CountryCode":"US","IsWellKnownMixedDrink":null,"ProductKeywords":"Bear|Walker"}',
    },
    {
        "role": "user",
        "content": "Establishment: Frankie J's (Nashville)\nIdentify this bar/restaurant POS item:\n\nPride Pitcher Garage",
    },
    {
        "role": "assistant",
        "content": '{"Brand":"Garage Beer Co.","BrandNameShort":"Garage","BrandKeywords":"Garage","ProductName":"Garage Beer Classic Light Beer","ContainerSizeQty":"60","ContainerSizeUnit":"Ounce","ContainerType":"Pitcher","ABV":"4.3%","ProductType":"Beer","ProductCategory":"Pilsner and Pale Lager","Country":"Spain","City":"Barcelona","StateProv":null,"CountryCode":"ES","IsWellKnownMixedDrink":null,"ProductKeywords":"Classic|Light"}',
    },
    {
        "role": "user",
        "content": "Establishment: Golden Pony (Nashville)\nIdentify this bar/restaurant POS item:\n\nHazy Fox",
    },
    {
        "role": "assistant",
        "content": '{"Brand":"New Realm Brewing Company","BrandNameShort":"New Realm","BrandKeywords":"New|Realm","ProductName":"New Realm Hazy Fox Hazy IPA","ContainerSizeQty":null,"ContainerSizeUnit":"Ounce","ContainerType":"Beer Glass","ABV":"6.5%","ProductType":"Beer","ProductCategory":"India Pale Ale (IPA)","Country":"United States","City":"Atlanta","StateProv":"Georgia","CountryCode":"US","IsWellKnownMixedDrink":null,"ProductKeywords":"Fox"}',
    },
    {
        "role": "user",
        "content": "Establishment: Golden Pony (Nashville)\nIdentify this bar/restaurant POS item:\n\nFrench 75",
    },
    {
        "role": "assistant",
        "content": '{"Brand":null,"BrandNameShort":null,"BrandKeywords":null,"ProductName":"Generic French 75","ContainerSizeQty":null,"ContainerSizeUnit":"Drink","ContainerType":"Highball","ABV":null,"ProductType":"Mixed Drink","ProductCategory":"Mixed Drink","Country":null,"City":null,"StateProv":null,"CountryCode":null,"IsWellKnownMixedDrink":1,"ProductKeywords":null}',
    },
    {
        "role": "user",
        "content": "Establishment: Frankie J\'s (Nashville)\nIdentify this bar/restaurant POS item:\n\nCuervo Marg",
    },
    {
        "role": "assistant",
        "content": '{"Brand":"Jose Cuervo","BrandNameShort":"Jose Cuervo","BrandKeywords":"Jose|Cuervo","ProductName":"Cuervo Margarita","ContainerSizeQty":null,"ContainerSizeUnit":"Drink","ContainerType":"Highball","ABV":null,"ProductType":"Mixed Drink","ProductCategory":"Mixed Drink","Country":"Mexico","City":null,"StateProv":null,"CountryCode":"MX","IsWellKnownMixedDrink":1,"ProductKeywords":null}',
    },
    {
        "role": "user",
        "content": "Establishment: Martha My Dear (Nashville)\nIdentify this bar/restaurant POS item:\n\nSB Margarita",
    },
    {
        "role": "assistant",
        "content": '{"Brand":"Southbound","BrandNameShort":"Southbound","BrandKeywords":"Southbound","ProductName":"Southbound Margarita","ContainerSizeQty":null,"ContainerSizeUnit":"Drink","ContainerType":"Highball","ABV":null,"ProductType":"Mixed Drink","ProductCategory":"Mixed Drink","Country":null,"City":null,"StateProv":null,"CountryCode":null,"IsWellKnownMixedDrink":1,"ProductKeywords":null}',
    },
    {
        "role": "user",
        "content": "Establishment: Martha My Dear (Nashville)\nIdentify this bar/restaurant POS item:\n\nSB Esp Martini",
    },
    {
        "role": "assistant",
        "content": '{"Brand":"Southbound","BrandNameShort":"Southbound","BrandKeywords":"Southbound","ProductName":"Southbound Espresso Martini","ContainerSizeQty":null,"ContainerSizeUnit":"Drink","ContainerType":"Generic Glass","ABV":null,"ProductType":"Mixed Drink","ProductCategory":"Mixed Drink","Country":null,"City":null,"StateProv":null,"CountryCode":null,"IsWellKnownMixedDrink":1,"ProductKeywords":null}',
    },
]

# Few-shot examples for Claude batch mode — one exchange showing a 3-item batch.
# Never mutate this list; ask_claude_batch() uses the + operator per call.
CLAUDE_BATCH_FEW_SHOT_MESSAGES = [
    {
        "role": "user",
        "content": (
            "Identify the following 4 bar/restaurant POS items. "
            "Return a JSON array of exactly 4 objects in the same order, one per item.\n\n"
            "1. [Martha My Dear (Nashville)]: \"Dickel BiB POTW\"\n"
            "2. [Frankie J's (Nashville)]: \"Pride Pitcher Garage\"\n"
            "3. [Live Oak (Nashville)]: \"No Pickle\"\n"
            "4. [Golden Pony (Nashville)]: \"Hazy Fox\""
        ),
    },
    {
        "role": "assistant",
        "content": (
            '[\n'
            '  {"Brand":"Dickel","BrandNameShort":"Dickel","BrandKeywords":"Dickel","ProductName":"Dickel Bottled in Bond Bourbon Whiskey",'
            '"ContainerSizeQty":null,"ContainerSizeUnit":"Shot","ContainerType":"Shot Glass",'
            '"ABV":"45%","ProductType":"Liquor","ProductCategory":"Bourbon",'
            '"Country":"United States","City":"Tullahoma","StateProv":"Tennessee","CountryCode":"US",'
            '"IsWellKnownMixedDrink":null,"ProductKeywords":"Bottled|Bond"},\n'
            '  {"Brand":"Garage Beer Co.","BrandNameShort":"Garage","BrandKeywords":"Garage","ProductName":"Garage Beer Classic Light Beer",'
            '"ContainerSizeQty":"60","ContainerSizeUnit":"Ounce","ContainerType":"Pitcher",'
            '"ABV":"4.3%","ProductType":"Beer","ProductCategory":"Pilsner and Pale Lager",'
            '"Country":"Spain","City":"Barcelona","StateProv":null,"CountryCode":"ES",'
            '"IsWellKnownMixedDrink":null,"ProductKeywords":"Classic|Light"},\n'
            '  {"Brand":null,"BrandNameShort":null,"BrandKeywords":null,"ProductName":"No Pickle","ContainerSizeQty":null,'
            '"ContainerSizeUnit":"Each","ContainerType":"Part","ABV":null,'
            '"ProductType":"Food","ProductCategory":"Food",'
            '"Country":null,"City":null,"StateProv":null,"CountryCode":null,'
            '"IsWellKnownMixedDrink":null,"ProductKeywords":null},\n'
            '  {"Brand":"New Realm Brewing Company","BrandNameShort":"New Realm","BrandKeywords":"New|Realm","ProductName":"New Realm Hazy Fox Hazy IPA",'
            '"ContainerSizeQty":null,"ContainerSizeUnit":"Ounce","ContainerType":"Beer Glass",'
            '"ABV":"6.5%","ProductType":"Beer","ProductCategory":"India Pale Ale (IPA)",'
            '"Country":"United States","City":"Atlanta","StateProv":"Georgia","CountryCode":"US",'
            '"IsWellKnownMixedDrink":null,"ProductKeywords":"Fox"}\n'
            ']'
        ),
    },
]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def strip_accents(text: str) -> str:
    """Remove diacritical marks and accent characters (e.g. é→e, ñ→n, ó→o)."""
    return "".join(
        c for c in unicodedata.normalize("NFD", text)
        if unicodedata.category(c) != "Mn"
    )


def strip_code_fences(text: str) -> str:
    """Remove markdown code fences from model responses."""
    text = text.strip()
    # Remove ```json ... ``` or ``` ... ```
    text = re.sub(r"^```(?:json)?\s*\n?", "", text)
    text = re.sub(r"\n?```\s*$", "", text)
    return text.strip()


def parse_json_response(text: str) -> dict:
    """Parse JSON from a model response, stripping code fences if present.
    Skips any preamble before the first '{' and ignores trailing content."""
    cleaned = strip_code_fences(text)
    start = cleaned.find("{")
    if start == -1:
        raise json.JSONDecodeError("No JSON object found in response", cleaned, 0)
    data, _ = json.JSONDecoder().raw_decode(cleaned, start)
    return data


def parse_json_array_response(text: str) -> list:
    """Parse a JSON array from a model response, stripping code fences if present.
    Skips any preamble before the first '[' and ignores trailing content."""
    cleaned = strip_code_fences(text)
    start = cleaned.find("[")
    if start == -1:
        raise json.JSONDecodeError("No JSON array found in response", cleaned, 0)
    data, _ = json.JSONDecoder().raw_decode(cleaned, start)
    if not isinstance(data, list):
        raise ValueError(f"Expected JSON array, got {type(data).__name__}")
    return data


def normalize_result(data: dict, logger: Optional[logging.Logger] = None) -> dict:
    """Ensure all expected fields exist in the result dict."""
    result = {}
    for field in FIELDS:
        val = data.get(field)
        if val is None or (isinstance(val, str) and val.strip().lower() in ("", "null", "none", "n/a", "unknown")):
            result[field] = None
        else:
            result[field] = strip_accents(str(val).strip())
    # Enforce permissible ProductType values
    pt = result.get("ProductType")
    if pt is not None and pt not in PRODUCT_TYPES:
        if logger:
            logger.warning(f"  Invalid ProductType '{pt}' — setting to 'Undefined'")
        result["ProductType"] = "Undefined"
    # Enforce permissible ContainerType values
    ct = result.get("ContainerType")
    if ct is not None and ct not in CONTAINER_TYPES:
        if logger:
            logger.warning(f"  Invalid ContainerType '{ct}' — setting to 'Undefined'")
        result["ContainerType"] = "Undefined"
    # Enforce permissible ContainerSizeUnit values
    csu = result.get("ContainerSizeUnit")
    if csu is not None and csu not in CONTAINER_SIZE_UNITS:
        if logger:
            logger.warning(f"  Invalid ContainerSizeUnit '{csu}' — setting to 'Undefined'")
        result["ContainerSizeUnit"] = "Undefined"
    # Enforce permissible ProductCategory values
    pc = result.get("ProductCategory")
    if pc is not None and pc not in PRODUCT_CATEGORIES:
        if logger:
            logger.warning(f"  Invalid ProductCategory '{pc}' — setting to 'Undefined'")
        result["ProductCategory"] = "Undefined"
    # Handle IsWellKnownMixedDrink — must be integer 0/1 or None, never a string
    if result.get("ProductType") == "Mixed Drink":
        raw = data.get("IsWellKnownMixedDrink")
        if raw in (1, True, "1", "true", "True"):
            result["IsWellKnownMixedDrink"] = 1
        elif raw in (0, False, "0", "false", "False"):
            result["IsWellKnownMixedDrink"] = 0
        else:
            result["IsWellKnownMixedDrink"] = None
    else:
        result["IsWellKnownMixedDrink"] = None
    # ProductKeywords: null when no brand (mixed drinks and food have no catalog to search)
    if result.get("Brand") is None:
        result["ProductKeywords"] = None
    # BrandNameShort / BrandKeywords: null when no brand
    if result.get("Brand") is None:
        result["BrandNameShort"] = None
        result["BrandKeywords"] = None
    # CountryCode: must be exactly 2 uppercase alpha chars, or null
    cc = result.get("CountryCode")
    if cc is not None:
        cc_clean = cc.strip().upper()
        if len(cc_clean) == 2 and cc_clean.isalpha():
            result["CountryCode"] = cc_clean
        else:
            if logger:
                logger.warning(f"  Invalid CountryCode '{cc}' — setting to null")
            result["CountryCode"] = None
    # CountryCode must be null when Country is null
    if result.get("Country") is None:
        result["CountryCode"] = None
    result = apply_default_sizes(result)
    return result


def apply_default_sizes(result: dict) -> dict:
    """Apply ContainerSizeQty/Unit defaults based on product type and container when not explicit."""
    qty = (result.get("ContainerSizeQty") or "").strip()
    unit = (result.get("ContainerSizeUnit") or "").strip()
    pt = (result.get("ProductType") or "").strip()
    ct = (result.get("ContainerType") or "").strip()
    pc = (result.get("ProductCategory") or "").strip()

    qty_missing = not qty or qty.lower() in ("null", "undefined", "none")
    unit_missing = not unit or unit.lower() in ("null", "undefined", "none")

    if not qty_missing and not unit_missing:
        return result

    # (a) Each, Drink, or Shot unit → qty = 1
    if unit in ("Each", "Drink", "Shot"):
        if qty_missing:
            result["ContainerSizeQty"] = "1"
        return result

    # (b/c) Beer container type
    if pt == "Beer":
        if ct in ("Can", "Bottle"):
            if qty_missing:  result["ContainerSizeQty"] = "12"
            if unit_missing: result["ContainerSizeUnit"] = "Ounce"
        elif ct == "Draft":
            if qty_missing:  result["ContainerSizeQty"] = "16"
            if unit_missing: result["ContainerSizeUnit"] = "Ounce"
        return result

    # (d/e) Wine
    if pt == "Wine":
        if pc == "Sparkling Wine":
            if qty_missing:  result["ContainerSizeQty"] = "4"
            if unit_missing: result["ContainerSizeUnit"] = "Ounce"
        else:
            if qty_missing:  result["ContainerSizeQty"] = "5"
            if unit_missing: result["ContainerSizeUnit"] = "Ounce"
        return result

    # (f) Shot Glass container — always expressed as a shot count
    if ct == "Shot Glass":
        if qty_missing:  result["ContainerSizeQty"] = "1"
        if unit_missing: result["ContainerSizeUnit"] = "Shot"
        return result

    return result


class TwoModelsFailedError(RuntimeError):
    """Raised when two AI models fail on the same item — triggers program halt."""


def results_disagree(result_a: dict, result_b: dict) -> bool:
    """Return True if two result dicts differ on ProductType, Brand, or ProductName."""
    def _n(s):
        return (s or "").strip().lower()
    return (
        _n(result_a.get("ProductType")) != _n(result_b.get("ProductType"))
        or _n(result_a.get("Brand")) != _n(result_b.get("Brand"))
        or _n(result_a.get("ProductName")) != _n(result_b.get("ProductName"))
    )


def sql_escape(value: Optional[str]) -> str:
    """Escape a string for SQL insertion, or return NULL."""
    if value is None:
        return "NULL"
    # Strip null bytes (SQL Server rejects them in varchar columns) then escape single quotes
    escaped = value.replace("\x00", "").replace("'", "''")
    return f"'{escaped}'"


def sql_int(value) -> str:
    """Format an integer (0 or 1) for SQL insertion, or return NULL."""
    if value is None:
        return "NULL"
    return str(int(value))


def calculate_total_cost(token_usage: dict) -> float:
    """Return total estimated cost in USD from accumulated token usage."""
    return sum(
        (token_usage[m]["input"]  / 1_000_000) * PRICING[m]["input"] +
        (token_usage[m]["output"] / 1_000_000) * PRICING[m]["output"]
        for m in ("claude", "openai", "gemini")
    )


def _is_rate_limit_error(exc: Exception) -> bool:
    """Return True if the exception looks like an API rate-limit (HTTP 429) error."""
    if isinstance(exc, (anthropic.RateLimitError, openai.RateLimitError)):
        return True
    # Gemini / google-genai surfaces rate limits via various exception types;
    # checking the string representation is more stable across SDK versions.
    msg = str(exc).lower()
    return any(tok in msg for tok in ("429", "quota", "rate limit", "resource_exhausted"))


def retry_with_backoff(func, description: str, logger: logging.Logger):
    """Call func() with retry and exponential backoff. Returns the result.

    Rate-limit errors use a longer fixed delay (RATE_LIMIT_RETRY_DELAY).
    JSON parse errors and other API errors use exponential backoff.
    """
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            return func()
        except json.JSONDecodeError as e:
            # JSON errors are usually deterministic at temperature=0, but a transient
            # truncation can cause them — still worth retrying once or twice.
            logger.warning(f"  JSON parse error on {description} (attempt {attempt}/{MAX_RETRIES}): {e}")
            retry_delay = RETRY_BASE_DELAY ** attempt
        except Exception as e:
            if _is_rate_limit_error(e):
                logger.warning(
                    f"  Rate-limit error on {description} (attempt {attempt}/{MAX_RETRIES}): {e}"
                )
                retry_delay = RATE_LIMIT_RETRY_DELAY
            else:
                logger.warning(f"  API error on {description} (attempt {attempt}/{MAX_RETRIES}): {e}")
                retry_delay = RETRY_BASE_DELAY ** attempt
        if attempt < MAX_RETRIES:
            logger.info(f"  Retrying {description} in {retry_delay}s...")
            time.sleep(retry_delay)
    raise RuntimeError(f"Failed {description} after {MAX_RETRIES} attempts")

# ---------------------------------------------------------------------------
# API callers
# ---------------------------------------------------------------------------
def ask_claude(client: anthropic.Anthropic, item_description: str,
               bar_name: str, logger: logging.Logger, token_usage: dict) -> dict:
    """Ask Claude Sonnet 4.6 to identify the product (primary model)."""
    def _call():
        user_msg = (
            f"Establishment: {bar_name}\n"
            f"Identify this bar/restaurant POS item:\n\n{item_description}"
        )
        response = client.messages.create(
            model=CLAUDE_MODEL,
            max_tokens=1024,
            temperature=0,
            system=CLAUDE_SYSTEM_PROMPT,
            messages=CLAUDE_FEW_SHOT_MESSAGES + [{"role": "user", "content": user_msg}],
        )
        token_usage["claude"]["input"]  += response.usage.input_tokens
        token_usage["claude"]["output"] += response.usage.output_tokens
        token_usage["claude"]["calls"]  += 1
        text = response.content[0].text
        logger.debug(f"  Claude raw response: {text}")
        data = parse_json_response(text)
        return normalize_result(data, logger)

    return retry_with_backoff(_call, "Claude", logger)


def ask_openai(client: openai.OpenAI, item_description: str,
               bar_name: str, claude_result: dict,
               logger: logging.Logger, token_usage: dict) -> tuple[bool, dict]:
    """Ask GPT-4o to verify Claude's interpretation. Returns (agrees, result)."""
    def _call():
        user_content = (
            f"Establishment: {bar_name}\n"
            f"Original POS item description: {item_description}\n\n"
            f"Previous model's interpretation:\n{json.dumps(claude_result, indent=2)}"
        )
        response = client.chat.completions.create(
            model=OPENAI_MODEL,
            max_tokens=1024,
            temperature=0,
            messages=[
                {"role": "system", "content": OPENAI_SYSTEM_PROMPT},
                *OPENAI_FEW_SHOT_MESSAGES,
                {"role": "user",   "content": user_content},
            ],
        )
        token_usage["openai"]["input"]  += response.usage.prompt_tokens
        token_usage["openai"]["output"] += response.usage.completion_tokens
        token_usage["openai"]["calls"]  += 1
        text = response.choices[0].message.content
        logger.debug(f"  OpenAI raw response: {text}")
        data = parse_json_response(text)
        agrees = data.get("agrees", True)
        result = normalize_result(data.get("result") or claude_result, logger)
        return agrees, result

    return retry_with_backoff(_call, "OpenAI", logger)


def ask_gemini(client: genai.Client, item_description: str,
               bar_name: str, claude_result: dict, openai_result: dict,
               logger: logging.Logger, token_usage: dict) -> dict:
    """Ask Gemini 2.5 Flash to arbitrate between Claude and OpenAI.
    Falls back to Claude's result if Gemini consistently fails."""
    def _call():
        user_content = (
            f"Establishment: {bar_name}\n"
            f"Original POS item description: {item_description}\n\n"
            f"Model A (Claude) interpretation:\n{json.dumps(claude_result, indent=2)}\n\n"
            f"Model B (OpenAI) interpretation:\n{json.dumps(openai_result, indent=2)}"
        )
        response = client.models.generate_content(
            model=GEMINI_MODEL,
            contents=[{"role": "user", "parts": [{"text": user_content}]}],
            config=genai_types.GenerateContentConfig(
                temperature=0.0,
                system_instruction=GEMINI_SYSTEM_PROMPT,
            ),
        )
        if response.usage_metadata:
            token_usage["gemini"]["input"]  += response.usage_metadata.prompt_token_count or 0
            token_usage["gemini"]["output"] += response.usage_metadata.candidates_token_count or 0
        token_usage["gemini"]["calls"] += 1
        try:
            text = response.text or ""
        except Exception as exc:
            raise ValueError("Gemini returned empty response") from exc
        if not text.strip():
            if response.candidates and response.candidates[0].finish_reason:
                reason = response.candidates[0].finish_reason
                logger.warning(f"  Gemini returned empty response (reason: {reason})")
            raise ValueError("Gemini returned empty response")
        logger.debug(f"  Gemini raw response: {text}")
        data = parse_json_response(text)
        winner = data.get("winner", "A")
        result = normalize_result(data.get("result") or claude_result, logger)
        logger.info(f"  Gemini chose: {winner}")
        return result

    try:
        return retry_with_backoff(_call, "Gemini", logger)
    except RuntimeError:
        logger.warning("  Gemini unavailable — Claude and OpenAI disagree; using Claude (Anthropic priority).")
        return claude_result

def ask_openai_identify(client: openai.OpenAI, item_description: str,
                        bar_name: str, logger: logging.Logger, token_usage: dict) -> dict:
    """Ask GPT-4o to independently identify the product (used when Claude is unavailable)."""
    def _call():
        user_msg = (
            f"Establishment: {bar_name}\n"
            f"Identify this bar/restaurant POS item:\n\n{item_description}"
        )
        response = client.chat.completions.create(
            model=OPENAI_MODEL,
            max_tokens=1024,
            temperature=0,
            messages=[
                {"role": "system", "content": CLAUDE_SYSTEM_PROMPT},
                *CLAUDE_FEW_SHOT_MESSAGES,
                {"role": "user", "content": user_msg},
            ],
        )
        token_usage["openai"]["input"]  += response.usage.prompt_tokens
        token_usage["openai"]["output"] += response.usage.completion_tokens
        token_usage["openai"]["calls"]  += 1
        text = response.choices[0].message.content
        logger.debug(f"  OpenAI identify raw response: {text}")
        data = parse_json_response(text)
        return normalize_result(data, logger)

    return retry_with_backoff(_call, "OpenAI identify", logger)


def ask_gemini_identify(client: genai.Client, item_description: str,
                        bar_name: str, logger: logging.Logger, token_usage: dict) -> dict:
    """Ask Gemini to independently identify the product (used when another model is unavailable).

    Raises RuntimeError on failure — no silent fallback so the caller can detect
    a second model failure and halt.
    """
    def _call():
        user_content = (
            f"Establishment: {bar_name}\n"
            f"Identify this bar/restaurant POS item:\n\n{item_description}"
        )
        response = client.models.generate_content(
            model=GEMINI_MODEL,
            contents=[{"role": "user", "parts": [{"text": user_content}]}],
            config=genai_types.GenerateContentConfig(
                temperature=0.0,
                system_instruction=CLAUDE_SYSTEM_PROMPT,
            ),
        )
        if response.usage_metadata:
            token_usage["gemini"]["input"]  += response.usage_metadata.prompt_token_count or 0
            token_usage["gemini"]["output"] += response.usage_metadata.candidates_token_count or 0
        token_usage["gemini"]["calls"] += 1
        try:
            text = response.text or ""
        except Exception as exc:
            raise ValueError("Gemini identify returned empty response") from exc
        if not text.strip():
            if response.candidates and response.candidates[0].finish_reason:
                reason = response.candidates[0].finish_reason
                logger.warning(f"  Gemini identify returned empty response (reason: {reason})")
            raise ValueError("Gemini identify returned empty response")
        logger.debug(f"  Gemini identify raw response: {text}")
        data = parse_json_response(text)
        return normalize_result(data, logger)

    return retry_with_backoff(_call, "Gemini identify", logger)


# ---------------------------------------------------------------------------
# Batch API callers  (BATCH_SIZE items per API call)
# ---------------------------------------------------------------------------
def ask_gemini_batch(client: genai.Client, disagree_items: list[dict],
                     logger: logging.Logger, token_usage: dict) -> list[dict]:
    """Ask Gemini 2.5 Flash to arbitrate a batch of disagreements.

    disagree_items: list of dicts with keys bar_name, description,
                    claude_result, openai_result.
    Returns one arbitrated result per item. Falls back to claude_result on failure.
    """
    n = len(disagree_items)

    def _call():
        item_sections = []
        for i, item in enumerate(disagree_items):
            item_sections.append(
                f"Item {i + 1}:\n"
                f"Establishment: {item['bar_name']}\n"
                f"Original POS description: \"{item['description']}\"\n"
                f"Model A (Claude):\n{json.dumps(item['claude_result'], indent=2)}\n"
                f"Model B (OpenAI):\n{json.dumps(item['openai_result'], indent=2)}"
            )
        user_content = (
            f"Arbitrate the following {n} items where two models disagreed. "
            f"Return a JSON array of exactly {n} objects in the same order.\n\n"
            + "\n\n".join(item_sections)
        )
        response = client.models.generate_content(
            model=GEMINI_MODEL,
            contents=[{"role": "user", "parts": [{"text": user_content}]}],
            config=genai_types.GenerateContentConfig(
                temperature=0.0,
                system_instruction=GEMINI_BATCH_ARBITRATION_SYSTEM_PROMPT,
            ),
        )
        if response.usage_metadata:
            token_usage["gemini"]["input"]  += response.usage_metadata.prompt_token_count or 0
            token_usage["gemini"]["output"] += response.usage_metadata.candidates_token_count or 0
        token_usage["gemini"]["calls"] += 1
        try:
            text = response.text or ""
        except Exception:
            text = ""
        if not text.strip():
            if response.candidates and response.candidates[0].finish_reason:
                reason = response.candidates[0].finish_reason
                logger.warning(f"  Gemini batch returned empty response (reason: {reason})")
            raise ValueError("Gemini batch returned empty response")
        logger.debug(f"  Gemini batch raw response: {text}")
        data = parse_json_array_response(text)
        if len(data) != n:
            raise ValueError(f"Gemini returned {len(data)} results for {n} items")
        out = []
        for item_data, orig in zip(data, disagree_items):
            winner = item_data.get("winner", "A")
            result = normalize_result(item_data.get("result") or orig["claude_result"], logger)
            logger.info(f"  Gemini winner: {winner}")
            out.append(result)
        return out

    try:
        return retry_with_backoff(_call, f"Gemini batch({n})", logger)
    except RuntimeError:
        logger.warning("  Gemini unavailable for batch — using Claude results (Anthropic priority).")
        results = []
        for item in disagree_items:
            cr = item["claude_result"]
            if not cr.get("ProductType") and not cr.get("ProductName"):
                logger.warning(
                    f"  Fallback claude_result has no ProductType or ProductName "
                    f"(bar={item.get('bar_name')!r}, desc={item.get('description','')[:60]!r}) — "
                    f"output for this item may be empty"
                )
            results.append(cr)
        return results


def ask_claude_batch(client: anthropic.Anthropic, items: list[dict],
                     logger: logging.Logger, token_usage: dict) -> list[dict]:
    """Ask Claude to identify a batch of products. Returns one result per item."""
    n = len(items)

    def _call():
        item_lines = "\n".join(
            f"{i + 1}. [{item['bar_name']}]: \"{item['description']}\""
            for i, item in enumerate(items)
        )
        user_msg = (
            f"Identify the following {n} bar/restaurant POS items. "
            f"Return a JSON array of exactly {n} objects in the same order, one per item.\n\n"
            f"{item_lines}"
        )
        response = client.messages.create(
            model=CLAUDE_MODEL,
            max_tokens=max(1024, 768 * n),
            temperature=0,
            system=CLAUDE_SYSTEM_PROMPT,
            messages=CLAUDE_BATCH_FEW_SHOT_MESSAGES + [{"role": "user", "content": user_msg}],
        )
        token_usage["claude"]["input"]  += response.usage.input_tokens
        token_usage["claude"]["output"] += response.usage.output_tokens
        token_usage["claude"]["calls"]  += 1
        text = response.content[0].text
        logger.debug(f"  Claude batch raw response: {text}")
        data = parse_json_array_response(text)
        if len(data) != n:
            raise ValueError(f"Claude returned {len(data)} results for {n} items")
        return [normalize_result(item, logger) for item in data]

    return retry_with_backoff(_call, f"Claude batch({n})", logger)


def ask_openai_batch(client: openai.OpenAI, items: list[dict],
                     claude_results: list[dict],
                     logger: logging.Logger, token_usage: dict) -> list[tuple[bool, dict]]:
    """Ask GPT-4o to verify Claude's results for a batch. Returns (agrees, result) per item."""
    n = len(items)

    def _call():
        item_sections = []
        for i, (item, cr) in enumerate(zip(items, claude_results)):
            item_sections.append(
                f"Item {i + 1}:\n"
                f"Establishment: {item['bar_name']}\n"
                f"Original POS description: \"{item['description']}\"\n"
                f"Previous model's interpretation:\n{json.dumps(cr, indent=2)}"
            )
        user_content = (
            f"For each of the following {n} items, verify whether the previous model's "
            f"interpretation is correct. Return a JSON array of exactly {n} objects in the "
            f"same order.\n\n"
            + "\n\n".join(item_sections)
        )
        response = client.chat.completions.create(
            model=OPENAI_MODEL,
            max_tokens=max(1024, 768 * n),
            temperature=0,
            messages=[
                {"role": "system", "content": OPENAI_SYSTEM_PROMPT},
                *OPENAI_FEW_SHOT_MESSAGES,
                {"role": "user",   "content": user_content},
            ],
        )
        token_usage["openai"]["input"]  += response.usage.prompt_tokens
        token_usage["openai"]["output"] += response.usage.completion_tokens
        token_usage["openai"]["calls"]  += 1
        text = response.choices[0].message.content
        logger.debug(f"  OpenAI batch raw response: {text}")
        data = parse_json_array_response(text)
        if len(data) != n:
            raise ValueError(f"OpenAI returned {len(data)} results for {n} items")
        out = []
        for item_data, cr in zip(data, claude_results):
            agrees = item_data.get("agrees", True)
            result = normalize_result(item_data.get("result") or cr, logger)
            out.append((agrees, result))
        return out

    return retry_with_backoff(_call, f"OpenAI batch({n})", logger)


# ---------------------------------------------------------------------------
# Batch orchestration helpers
# ---------------------------------------------------------------------------
def process_batch(batch: list[dict],
                  claude_client, openai_client, gemini_client,
                  logger: logging.Logger, token_usage: dict) -> list[dict]:
    """Run a full batch through Claude → OpenAI → Gemini (for disagreements).

    Returns a list of {"result": dict, "status": "agreement"|"disagreement"} in
    the same order as batch.  Raises on unrecoverable batch failure so the caller
    can fall back to process_individually().
    """
    n = len(batch)

    # Step 1 — Claude (primary identifier)
    logger.info(f"  Asking Claude (batch {n})...")
    claude_results = ask_claude_batch(claude_client, batch, logger, token_usage)

    # Step 2 — OpenAI verification
    logger.info(f"  Asking OpenAI to verify (batch {n})...")
    openai_outcomes = ask_openai_batch(openai_client, batch, claude_results, logger, token_usage)

    # Partition into agreements and disagreements
    final: list[Optional[dict]] = [None] * n
    disagree_items = []
    for i, (item, cr, (agrees, oai_r)) in enumerate(
            zip(batch, claude_results, openai_outcomes)):
        if agrees:
            logger.info(f"  Item {i + 1} ({item['description']!r}): OpenAI AGREES -> "
                        f"{cr.get('ProductName', '?')} ({cr.get('ProductType', '?')})")
            final[i] = {"result": cr, "status": "agreement"}
        else:
            logger.info(f"  Item {i + 1} ({item['description']!r}): OpenAI DISAGREES -> "
                        f"OpenAI says {oai_r.get('ProductName', '?')}")
            disagree_items.append({
                "index": i,
                "bar_name": item["bar_name"],
                "description": item["description"],
                "claude_result": cr,
                "openai_result": oai_r,
            })

    # Step 3 — Gemini arbitration for disagreements only
    if disagree_items:
        logger.info(f"  Asking Gemini to arbitrate {len(disagree_items)} disagreement(s)...")
        gemini_results = ask_gemini_batch(gemini_client, disagree_items, logger, token_usage)
        for info, gem_r in zip(disagree_items, gemini_results):
            final[info["index"]] = {"result": gem_r, "status": "disagreement"}

    # Sanity check — every slot must be filled; a None here is a logic error.
    unfilled = [i for i, v in enumerate(final) if v is None]
    if unfilled:
        raise RuntimeError(f"process_batch: unfilled result slots at indices {unfilled}")

    return final


def process_individually(batch: list[dict],
                         claude_client, openai_client, gemini_client,
                         logger: logging.Logger, token_usage: dict) -> list[dict]:
    """Process each item one-at-a-time, with single-model-failure recovery.

    If one model fails, the other two are used.  When the two remaining models
    disagree, priority determines the winner: Anthropic > Gemini > ChatGPT.
    Raises TwoModelsFailedError if two models fail on the same item.
    """
    out = []
    for item in batch:
        failed: set[str] = set()

        # --- Claude ---
        cr: Optional[dict] = None
        try:
            cr = ask_claude(claude_client, item["description"], item["bar_name"],
                            logger, token_usage)
        except RuntimeError as e:
            logger.warning(f"  Claude failed for ID={item['id']}: {e}")
            failed.add("claude")

        # --- OpenAI ---
        oai_r: Optional[dict] = None
        agrees: Optional[bool] = None
        try:
            if "claude" not in failed:
                agrees, oai_r = ask_openai(openai_client, item["description"],
                                           item["bar_name"], cr, logger, token_usage)
            else:
                # Claude unavailable — ask OpenAI to identify independently
                oai_r = ask_openai_identify(openai_client, item["description"],
                                            item["bar_name"], logger, token_usage)
        except RuntimeError as e:
            logger.warning(f"  OpenAI failed for ID={item['id']}: {e}")
            failed.add("openai")

        # --- Two-model failure: halt ---
        if len(failed) >= 2:
            logger.error(
                f"  Two models failed on ID={item['id']} "
                f"({', '.join(sorted(failed))}). Halting."
            )
            raise TwoModelsFailedError(
                f"Two models ({', '.join(sorted(failed))}) failed on item ID={item['id']}"
            )

        # --- Normal path: both Claude and OpenAI succeeded ---
        if not failed:
            if agrees:
                out.append({"result": cr, "status": "agreement"})
            else:
                # ask_gemini falls back to claude_result if Gemini itself errors,
                # which is correct: Claude (Anthropic) wins on priority.
                gem_r = ask_gemini(gemini_client, item["description"], item["bar_name"],
                                   cr, oai_r, logger, token_usage)
                out.append({"result": gem_r, "status": "disagreement"})
            continue

        # --- One-model-failed path: get Gemini's independent identification ---
        try:
            gem_r = ask_gemini_identify(gemini_client, item["description"],
                                        item["bar_name"], logger, token_usage)
        except RuntimeError as e:
            which = next(iter(failed))
            logger.error(
                f"  Gemini also failed for ID={item['id']} "
                f"({which} + gemini). Halting."
            )
            raise TwoModelsFailedError(
                f"Two models ({which} + gemini) failed on item ID={item['id']}"
            ) from e

        if "claude" in failed:
            # Remaining: OpenAI + Gemini.  Priority: Gemini > OpenAI.
            if not results_disagree(oai_r, gem_r):
                logger.info(f"  Claude failed. OpenAI + Gemini agree.")
                out.append({"result": oai_r, "status": "agreement"})
            else:
                logger.info(
                    f"  Claude failed; OpenAI+Gemini disagree — "
                    f"using Gemini (priority over ChatGPT)."
                )
                out.append({"result": gem_r, "status": "disagreement"})
        else:
            # "openai" in failed. Remaining: Claude + Gemini.  Priority: Claude > Gemini.
            if not results_disagree(cr, gem_r):
                logger.info(f"  OpenAI failed. Claude + Gemini agree.")
                out.append({"result": cr, "status": "agreement"})
            else:
                logger.info(
                    f"  OpenAI failed; Claude+Gemini disagree — "
                    f"using Claude (Anthropic priority)."
                )
                out.append({"result": cr, "status": "disagreement"})

    return out


# ---------------------------------------------------------------------------
# SQL generation
# ---------------------------------------------------------------------------
def generate_sql(results: list[dict], output_path: str):
    """Write SQL INSERT statements to the output file."""
    col_list = (
        "[fkImportStagingId], [ItemAsListed], [Brand], [BrandNameShort], [BrandKeywords], [ProductName], "
        "[ContainerSizeQty], [ContainerSizeUnit], [ContainerType], [ABV], "
        "[ProductType], [ProductCategory], [Country], [City], [StateProv], [CountryCode], "
        "[IsWellKnownMixedDrink], [ProductKeywords]"
    )

    with open(output_path, "w", encoding="utf-8") as f:
        f.write("SET NOCOUNT ON;\n\nBEGIN TRANSACTION;\n\n")
        for row in results:
            values = ", ".join([
                str(row["id"]),
                sql_escape(strip_accents(row["description"])),
                sql_escape(row["result"]["Brand"]),
                sql_escape(row["result"].get("BrandNameShort")),
                sql_escape(row["result"].get("BrandKeywords")),
                sql_escape(row["result"]["ProductName"]),
                sql_escape(row["result"]["ContainerSizeQty"]),
                sql_escape(row["result"]["ContainerSizeUnit"]),
                sql_escape(row["result"]["ContainerType"]),
                sql_escape(row["result"]["ABV"]),
                sql_escape(row["result"]["ProductType"]),
                sql_escape(row["result"]["ProductCategory"]),
                sql_escape(row["result"]["Country"]),
                sql_escape(row["result"]["City"]),
                sql_escape(row["result"]["StateProv"]),
                sql_escape(row["result"].get("CountryCode")),
                sql_int(row["result"].get("IsWellKnownMixedDrink")),
                sql_escape(row["result"].get("ProductKeywords")),
            ])
            f.write(
                f"INSERT INTO [TabX].[ImportStagingAI] ({col_list})\n"
                f"VALUES ({values});\n\n"
            )
        f.write("COMMIT;\n")

# ---------------------------------------------------------------------------
# CSV generation
# ---------------------------------------------------------------------------
CSV_COLUMNS = [
    "fkImportStagingId", "ItemAsListed", "Brand", "BrandNameShort", "BrandKeywords", "ProductName",
    "ContainerSizeQty", "ContainerSizeUnit", "ContainerType", "ABV",
    "ProductType", "ProductCategory", "Country", "City", "StateProv", "CountryCode",
    "IsWellKnownMixedDrink", "ProductKeywords",
]


def generate_csv(results: list[dict], output_path: str):
    """Write results to a CSV file with a header row."""
    with open(output_path, "w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(CSV_COLUMNS)
        for row in results:
            writer.writerow([
                row["id"],
                strip_accents(row["description"]),
                row["result"]["Brand"],
                row["result"].get("BrandNameShort"),
                row["result"].get("BrandKeywords"),
                row["result"]["ProductName"],
                row["result"]["ContainerSizeQty"],
                row["result"]["ContainerSizeUnit"],
                row["result"]["ContainerType"],
                row["result"]["ABV"],
                row["result"]["ProductType"],
                row["result"]["ProductCategory"],
                row["result"]["Country"],
                row["result"]["City"],
                row["result"]["StateProv"],
                row["result"].get("CountryCode"),
                row["result"].get("IsWellKnownMixedDrink"),
                row["result"].get("ProductKeywords"),
            ])


# ---------------------------------------------------------------------------
# Run log
# ---------------------------------------------------------------------------
RUN_LOG_COLUMNS = [
    "RunDate", "RunTime", "RowsProcessed",
    "ClaudeCalls", "OpenAICalls", "GeminiCalls",
    "ClaudeCost", "OpenAICost", "GeminiCost", "TotalCost",
]


def generate_run_log(run_log_path: str, run_dt: datetime, rows_processed: int,
                     token_usage: dict, costs: dict, total_cost: float):
    """Append a one-row summary of this run to the CSV run log."""
    log_path = Path(run_log_path)
    write_header = not log_path.exists() or log_path.stat().st_size == 0
    with open(run_log_path, "a", encoding="utf-8", newline="") as f:
        writer = csv.writer(f)
        if write_header:
            writer.writerow(RUN_LOG_COLUMNS)
        writer.writerow([
            run_dt.strftime("%Y-%m-%d"),
            run_dt.strftime("%H:%M:%S"),
            rows_processed,
            token_usage["claude"]["calls"],
            token_usage["openai"]["calls"],
            token_usage["gemini"]["calls"],
            f"{costs['claude']:.4f}",
            f"{costs['openai']:.4f}",
            f"{costs['gemini']:.4f}",
            f"{total_cost:.4f}",
        ])


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description="AI-powered bar/restaurant product identification"
    )
    parser.add_argument(
        "--input", "-i", required=True,
        help="Path to input TSV file (columns: pkImportStagingId, LocationNameCity, ItemAsListed)"
    )
    parser.add_argument(
        "--output", "-o", default="output.sql",
        help="Path to output SQL file (default: output.sql)"
    )
    parser.add_argument(
        "--log", default="bar_item_lookup.log",
        help="Path to log file (default: bar_item_lookup.log)"
    )
    parser.add_argument(
        "--delay", type=float, default=0.5,
        help="Delay in seconds between batches to respect rate limits (default: 0.5)"
    )
    parser.add_argument(
        "--max-items", "-n", type=int, default=None,
        help="Process at most this many items from the remaining (unprocessed) rows; useful for test runs"
    )
    parser.add_argument(
        "--encoding", default="cp1252",
        help="Input file encoding (default: cp1252 for Windows exports)"
    )
    parser.add_argument(
        "--run-log", default=None,
        help="Path to run history CSV log (default: run_log.csv next to --output)"
    )
    args = parser.parse_args()

    # Load .env
    env_path = Path(__file__).parent / ".env"
    if env_path.exists():
        load_dotenv(env_path)
    else:
        load_dotenv()  # Try default locations

    run_start = datetime.now()
    logger = setup_logging(args.log)
    logger.info("=" * 60)
    logger.info("Bar Item Lookup - AI-Powered Product Identification")
    logger.info("=" * 60)
    logger.info(f"Models: Claude={CLAUDE_MODEL} (primary), OpenAI={OPENAI_MODEL} (secondary), Gemini={GEMINI_MODEL} (tertiary)")

    # Validate API keys
    anthropic_key = os.getenv("ANTHROPIC_API_KEY")
    openai_key = os.getenv("OPENAI_API_KEY")
    google_key = os.getenv("GOOGLE_API_KEY")

    missing = []
    if not anthropic_key:
        missing.append("ANTHROPIC_API_KEY")
    if not openai_key:
        missing.append("OPENAI_API_KEY")
    if not google_key:
        missing.append("GOOGLE_API_KEY")
    if missing:
        logger.error(f"Missing API keys: {', '.join(missing)}")
        logger.error("Set them in a .env file or as environment variables.")
        sys.exit(1)

    # Initialize clients — use truststore SSLContext for corporate SSL inspection proxies
    _ssl_ctx = None
    if truststore is not None:
        try:
            _ssl_ctx = truststore.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        except Exception as e:
            logger.warning(f"Could not create truststore SSLContext: {e}")
    claude_client = anthropic.Anthropic(
        api_key=anthropic_key,
        **({"http_client": httpx.Client(verify=_ssl_ctx)} if _ssl_ctx else {}),
    )
    openai_client = openai.OpenAI(
        api_key=openai_key,
        **({"http_client": httpx.Client(verify=_ssl_ctx)} if _ssl_ctx else {}),
    )
    gemini_client = genai.Client(api_key=google_key)

    # Read TSV
    input_path = Path(args.input)
    if not input_path.exists():
        logger.error(f"Input file not found: {input_path}")
        sys.exit(1)

    rows = []
    with open(input_path, "r", encoding=args.encoding) as f:
        reader = csv.DictReader(f, delimiter="\t")
        expected_columns = {"pkImportStagingId", "LocationNameCity", "ItemAsListed"}
        missing_columns = expected_columns - set(reader.fieldnames or [])
        if missing_columns:
            logger.error(f"Input file is missing required columns: {', '.join(sorted(missing_columns))}")
            logger.error(f"Found columns: {reader.fieldnames}")
            sys.exit(1)
        seen_ids: set[int] = set()
        for row in reader:
            try:
                row_id = int(row["pkImportStagingId"])
            except (ValueError, TypeError):
                logger.error(f"Non-integer pkImportStagingId '{row['pkImportStagingId']}' — skipping row.")
                continue
            if row_id in seen_ids:
                logger.warning(f"Duplicate pkImportStagingId {row_id} in input — skipping.")
                continue
            seen_ids.add(row_id)
            description = (row["ItemAsListed"] or "").strip()
            if not description:
                logger.warning(f"ID={row_id}: empty description — skipping.")
                continue
            rows.append({
                "id": row_id,
                "bar_name": (row["LocationNameCity"] or "").strip() or "Unknown",
                "description": description,
            })

    total = len(rows)
    logger.info(f"Loaded {total} items from {input_path}")

    # Checkpoint / resume
    checkpoint_path = Path(args.output).with_suffix(".checkpoint.json")
    results = []
    agreements = 0
    disagreements = 0
    errors = 0
    token_usage = {
        "claude": {"input": 0, "output": 0, "calls": 0},
        "openai": {"input": 0, "output": 0, "calls": 0},
        "gemini": {"input": 0, "output": 0, "calls": 0},
    }
    processed_ids = set()

    if checkpoint_path.exists():
        try:
            with open(checkpoint_path, "r", encoding="utf-8") as f:
                cp = json.load(f)
            results       = cp.get("results", [])
            agreements    = cp.get("agreements", 0)
            disagreements = cp.get("disagreements", 0)
            errors        = cp.get("errors", 0)
            token_usage   = cp.get("token_usage", token_usage)
            for _m in ("claude", "openai", "gemini"):
                token_usage[_m].setdefault("calls", 0)
            processed_ids = {r["id"] for r in results}
            logger.info(f"Resuming from checkpoint — {len(processed_ids)} items already done.")
        except Exception as e:
            logger.warning(f"Could not load checkpoint ({e}); starting fresh.")

    rows = [r for r in rows if r["id"] not in processed_ids]
    logger.info(f"Items remaining: {len(rows)}")
    if args.max_items is not None:
        rows = rows[:args.max_items]
        logger.info(f"--max-items {args.max_items}: capped to {len(rows)} items for this run.")

    rows_this_run = len(rows)
    # Snapshot token costs accumulated before this run (from checkpoint) so the
    # cost guard below can measure only the current run's spend per item.
    run_start_cost = calculate_total_cost(token_usage)

    def save_checkpoint():
        with open(checkpoint_path, "w", encoding="utf-8") as f:
            json.dump({
                "results": results,
                "agreements": agreements,
                "disagreements": disagreements,
                "errors": errors,
                "token_usage": token_usage,
            }, f)


    items_done = 0
    total_batches = (len(rows) + BATCH_SIZE - 1) // BATCH_SIZE if rows else 0

    for batch_idx, batch_start in enumerate(range(0, len(rows), BATCH_SIZE), 1):
        batch = rows[batch_start:batch_start + BATCH_SIZE]
        n = len(batch)
        logger.info(f"--- Batch {batch_idx}/{total_batches} ({n} items) ---")
        for local_idx, item in enumerate(batch):
            logger.info(
                f"  [{len(processed_ids) + items_done + local_idx + 1}/{total}] "
                f"ID={item['id']} [{item['bar_name']}]: \"{item['description']}\""
            )

        # Attempt batch processing; fall back to one-at-a-time on failure
        try:
            outcomes = process_batch(
                batch, claude_client, openai_client, gemini_client, logger, token_usage
            )
        except Exception as e:
            logger.warning(f"  Batch failed ({e}) — retrying items individually...")
            try:
                outcomes = process_individually(
                    batch, claude_client, openai_client, gemini_client, logger, token_usage
                )
            except TwoModelsFailedError as fatal:
                logger.error(str(fatal))
                logger.error("Checkpoint preserved — check API status before resuming.")
                sys.exit(1)

        # Record each item's outcome
        for item, outcome in zip(batch, outcomes):
            items_done += 1
            status = outcome["status"]
            final_result = outcome["result"]

            if status == "agreement":
                agreements += 1
            elif status == "disagreement":
                disagreements += 1
            else:
                errors += 1

            logger.info(
                f"  Final [{item['id']}]: {final_result.get('Brand', '')} "
                f"{final_result.get('ProductName', '?')} ({final_result.get('ProductType', '?')})"
            )
            results.append({
                "id": item["id"],
                "description": item["description"],
                "result": final_result,
            })
            save_checkpoint()

            # Cost-per-item guard — measured against this run only so that a large
            # volume of cheap items from a previous checkpoint run cannot mask an
            # expensive rate on the current run.
            run_cost = calculate_total_cost(token_usage) - run_start_cost
            cost_per_item = run_cost / items_done
            if cost_per_item > COST_PER_ITEM_LIMIT:
                logger.error(
                    f"Cost per item ${cost_per_item:.4f} exceeds limit of "
                    f"${COST_PER_ITEM_LIMIT:.2f} after {items_done} items this run "
                    f"(run cost so far: ${run_cost:.4f}). Aborting."
                )
                logger.error("Checkpoint preserved — review costs before resuming.")
                sys.exit(1)

        # Delay between batches (not between items within a batch)
        if batch_start + BATCH_SIZE < len(rows):
            time.sleep(args.delay)

    # Generate SQL and CSV output
    logger.info("-" * 60)
    logger.info("Generating SQL output...")
    generate_sql(results, args.output)
    logger.info(f"SQL written to: {args.output}")

    csv_path = str(Path(args.output).with_suffix(".csv"))
    logger.info("Generating CSV output...")
    generate_csv(results, csv_path)
    logger.info(f"CSV written to: {csv_path}")

    # Clean up checkpoint only after both files are safely written
    if checkpoint_path.exists():
        checkpoint_path.unlink()

    # Cost calculation
    costs = {
        model: (
            (token_usage[model]["input"]  / 1_000_000) * PRICING[model]["input"] +
            (token_usage[model]["output"] / 1_000_000) * PRICING[model]["output"]
        )
        for model in ("claude", "openai", "gemini")
    }
    total_cost = calculate_total_cost(token_usage)

    # Run log
    run_log_path = args.run_log or str(Path(args.output).parent / "run_log.csv")
    try:
        generate_run_log(run_log_path, run_start, rows_this_run, token_usage, costs, total_cost)
        logger.info(f"Run log appended to: {run_log_path}")
    except PermissionError:
        logger.warning(
            f"Could not write run log to '{run_log_path}' — file may be open in another program. "
            "Close it and the next run will append normally."
        )

    # Summary
    logger.info("=" * 60)
    logger.info("SUMMARY")
    logger.info(f"  Total items:    {total}")
    logger.info(f"  Agreements:     {agreements} (Claude + OpenAI agreed)")
    logger.info(f"  Disagreements:  {disagreements} (Gemini arbitrated)")
    logger.info(f"  Errors:         {errors}")
    logger.info("-" * 60)
    logger.info("ESTIMATED COST")
    logger.info(f"  Gemini  — {token_usage['gemini']['input']:>7,} in / {token_usage['gemini']['output']:>6,} out — ${costs['gemini']:.4f}")
    logger.info(f"  Claude  — {token_usage['claude']['input']:>7,} in / {token_usage['claude']['output']:>6,} out — ${costs['claude']:.4f}")
    logger.info(f"  OpenAI  — {token_usage['openai']['input']:>7,} in / {token_usage['openai']['output']:>6,} out — ${costs['openai']:.4f}")
    logger.info(f"  TOTAL                                        ${total_cost:.4f}")
    logger.info("=" * 60)

    if errors > 0:
        logger.warning(f"{errors} items failed processing. Check the log for details.")
        sys.exit(1)


if __name__ == "__main__":
    main()

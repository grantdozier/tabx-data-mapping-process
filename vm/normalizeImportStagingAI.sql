-- normalizeImportStagingAI.sql
-- Run BEFORE updateImportStagingWithBrandAndProduct.sql
-- Normalizes noise in TabX.ImportStagingAI (Brand, ProductName, ItemAsListed,
-- ProductType, ProductCategory) to increase brand/product match rates.

--use TabX
--GO

-- ============================================================
-- Pass 1a -- Control characters, whitespace trim, null-collapse empty strings
-- Replaces tab/LF/CR with space, trims leading/trailing whitespace,
-- and collapses empty strings to NULL on nullable columns.
-- ItemAsListed is NOT NULL so NULLIF is omitted for that column.
-- ============================================================
update TabX.ImportStagingAI
set
   Brand           = nullif(trim(replace(replace(replace(Brand,           char(9), ' '), char(10), ' '), char(13), ' ')), '')
  ,ProductName     = nullif(trim(replace(replace(replace(ProductName,     char(9), ' '), char(10), ' '), char(13), ' ')), '')
  ,ItemAsListed    =        trim(replace(replace(replace(ItemAsListed,    char(9), ' '), char(10), ' '), char(13), ' '))
  ,ProductType     = nullif(trim(replace(replace(replace(ProductType,     char(9), ' '), char(10), ' '), char(13), ' ')), '')
  ,ProductCategory = nullif(trim(replace(replace(replace(ProductCategory, char(9), ' '), char(10), ' '), char(13), ' ')), '')
where    Brand           like '%' + char(9) + '%' or Brand           like '%' + char(10) + '%' or Brand           like '%' + char(13) + '%'
    or   Brand           like ' %'                or Brand           like '% '                or Brand           = ''
    or   ProductName     like '%' + char(9) + '%' or ProductName     like '%' + char(10) + '%' or ProductName     like '%' + char(13) + '%'
    or   ProductName     like ' %'                or ProductName     like '% '                or ProductName     = ''
    or   ItemAsListed    like '%' + char(9) + '%' or ItemAsListed    like '%' + char(10) + '%' or ItemAsListed    like '%' + char(13) + '%'
    or   ItemAsListed    like ' %'                or ItemAsListed    like '% '
    or   ProductType     like '%' + char(9) + '%' or ProductType     like '%' + char(10) + '%' or ProductType     like '%' + char(13) + '%'
    or   ProductType     like ' %'                or ProductType     like '% '                or ProductType     = ''
    or   ProductCategory like '%' + char(9) + '%' or ProductCategory like '%' + char(10) + '%' or ProductCategory like '%' + char(13) + '%'
    or   ProductCategory like ' %'                or ProductCategory like '% '                or ProductCategory = ''
GO

-- ============================================================
-- Pass 1b -- Collapse multiple consecutive spaces (4-deep nested replace;
-- handles runs of up to 16 spaces collapsing to 1)
-- ============================================================
update TabX.ImportStagingAI
set
   Brand           = replace(replace(replace(replace(Brand,           '  ', ' '), '  ', ' '), '  ', ' '), '  ', ' ')
  ,ProductName     = replace(replace(replace(replace(ProductName,     '  ', ' '), '  ', ' '), '  ', ' '), '  ', ' ')
  ,ItemAsListed    = replace(replace(replace(replace(ItemAsListed,    '  ', ' '), '  ', ' '), '  ', ' '), '  ', ' ')
  ,ProductType     = replace(replace(replace(replace(ProductType,     '  ', ' '), '  ', ' '), '  ', ' '), '  ', ' ')
  ,ProductCategory = replace(replace(replace(replace(ProductCategory, '  ', ' '), '  ', ' '), '  ', ' '), '  ', ' ')
where    Brand           like '%  %'
    or   ProductName     like '%  %'
    or   ItemAsListed    like '%  %'
    or   ProductType     like '%  %'
    or   ProductCategory like '%  %'
GO

-- ============================================================
-- Pass 2 -- Normalize Unicode punctuation stored as CP1252 bytes
-- char(145/146) = curly single quotes  (U+2018 / U+2019)
-- char(147/148) = curly double quotes  (U+201C / U+201D)
-- char(150/151) = en-dash / em-dash    (U+2013 / U+2014)
-- ============================================================
update TabX.ImportStagingAI
set
   Brand        = replace(replace(replace(replace(replace(replace(Brand,
                     char(145), ''''), char(146), ''''), char(147), '"'), char(148), '"'), char(150), '-'), char(151), '-')
  ,ProductName  = replace(replace(replace(replace(replace(replace(ProductName,
                     char(145), ''''), char(146), ''''), char(147), '"'), char(148), '"'), char(150), '-'), char(151), '-')
  ,ItemAsListed = replace(replace(replace(replace(replace(replace(ItemAsListed,
                     char(145), ''''), char(146), ''''), char(147), '"'), char(148), '"'), char(150), '-'), char(151), '-')
where    Brand        like '%' + char(145) + '%' or Brand        like '%' + char(146) + '%'
    or   Brand        like '%' + char(147) + '%' or Brand        like '%' + char(148) + '%'
    or   Brand        like '%' + char(150) + '%' or Brand        like '%' + char(151) + '%'
    or   ProductName  like '%' + char(145) + '%' or ProductName  like '%' + char(146) + '%'
    or   ProductName  like '%' + char(147) + '%' or ProductName  like '%' + char(148) + '%'
    or   ProductName  like '%' + char(150) + '%' or ProductName  like '%' + char(151) + '%'
    or   ItemAsListed like '%' + char(145) + '%' or ItemAsListed like '%' + char(146) + '%'
    or   ItemAsListed like '%' + char(147) + '%' or ItemAsListed like '%' + char(148) + '%'
    or   ItemAsListed like '%' + char(150) + '%' or ItemAsListed like '%' + char(151) + '%'
GO

-- ============================================================
-- Pass 3 -- Canonicalize 'Mixed Drink' brand casing
-- The main update script filters on Brand = 'Mixed Drink' (one branch)
-- and Brand <> 'mixed drink' (other branch); consistent casing is required.
-- ============================================================
update TabX.ImportStagingAI
set    Brand = 'Mixed Drink'
where  upper(Brand) = 'MIXED DRINK'
  and  Brand        <> 'Mixed Drink'
GO

-- ============================================================
-- Pass 4a -- Expand container/serving abbreviations (word-boundary safe)
-- Wraps column in leading/trailing spaces so abbreviations are replaced
-- only when they appear as whole tokens, never as substrings.
-- Longer variants (BTLE, DRFT) are placed in the innermost replace call
-- so they are resolved before the shorter overlapping variants (BTL, DFT).
-- Note: replace is case-insensitive on CI collations; on CS collations
--       add upper/lower variants to each replace chain as needed.
-- ============================================================
update TabX.ImportStagingAI
set
   Brand        = trim(replace(replace(replace(replace(replace(replace(replace(
                     ' ' + Brand + ' ',
                     ' BTLE ', ' Bottle '),
                     ' BTL ',  ' Bottle '),
                     ' DBL ',  ' Double '),
                     ' SGL ',  ' Single '),
                     ' DRFT ', ' Draft '),
                     ' DFT ',  ' Draft '),
                     ' W/ ',   ' With '))
  ,ProductName  = trim(replace(replace(replace(replace(replace(replace(replace(
                     ' ' + ProductName + ' ',
                     ' BTLE ', ' Bottle '),
                     ' BTL ',  ' Bottle '),
                     ' DBL ',  ' Double '),
                     ' SGL ',  ' Single '),
                     ' DRFT ', ' Draft '),
                     ' DFT ',  ' Draft '),
                     ' W/ ',   ' With '))
  ,ItemAsListed = trim(replace(replace(replace(replace(replace(replace(replace(
                     ' ' + ItemAsListed + ' ',
                     ' BTLE ', ' Bottle '),
                     ' BTL ',  ' Bottle '),
                     ' DBL ',  ' Double '),
                     ' SGL ',  ' Single '),
                     ' DRFT ', ' Draft '),
                     ' DFT ',  ' Draft '),
                     ' W/ ',   ' With '))
where  ' ' + isnull(Brand, '')        + ' ' like '% BTL %'  or ' ' + isnull(Brand, '')        + ' ' like '% BTLE %'
    or ' ' + isnull(Brand, '')        + ' ' like '% DBL %'  or ' ' + isnull(Brand, '')        + ' ' like '% SGL %'
    or ' ' + isnull(Brand, '')        + ' ' like '% DFT %'  or ' ' + isnull(Brand, '')        + ' ' like '% DRFT %'
    or ' ' + isnull(Brand, '')        + ' ' like '% W/ %'
    or ' ' + isnull(ProductName, '')  + ' ' like '% BTL %'  or ' ' + isnull(ProductName, '')  + ' ' like '% BTLE %'
    or ' ' + isnull(ProductName, '')  + ' ' like '% DBL %'  or ' ' + isnull(ProductName, '')  + ' ' like '% SGL %'
    or ' ' + isnull(ProductName, '')  + ' ' like '% DFT %'  or ' ' + isnull(ProductName, '')  + ' ' like '% DRFT %'
    or ' ' + isnull(ProductName, '')  + ' ' like '% W/ %'
    or ' ' + ItemAsListed             + ' ' like '% BTL %'  or ' ' + ItemAsListed             + ' ' like '% BTLE %'
    or ' ' + ItemAsListed             + ' ' like '% DBL %'  or ' ' + ItemAsListed             + ' ' like '% SGL %'
    or ' ' + ItemAsListed             + ' ' like '% DFT %'  or ' ' + ItemAsListed             + ' ' like '% DRFT %'
    or ' ' + ItemAsListed             + ' ' like '% W/ %'
GO

-- ============================================================
-- Pass 4b -- Expand 'Light' abbreviations: LT, LTE (word-boundary safe)
-- Handled in a separate pass because the LT token is common enough to
-- warrant an isolated WHERE clause, and LTE must be expanded before LT.
-- ============================================================
update TabX.ImportStagingAI
set
   Brand        = trim(replace(replace(' ' + Brand        + ' ', ' LTE ', ' Light '), ' LT ', ' Light '))
  ,ProductName  = trim(replace(replace(' ' + ProductName  + ' ', ' LTE ', ' Light '), ' LT ', ' Light '))
  ,ItemAsListed = trim(replace(replace(' ' + ItemAsListed + ' ', ' LTE ', ' Light '), ' LT ', ' Light '))
where  ' ' + isnull(Brand, '')        + ' ' like '% LT %'  or ' ' + isnull(Brand, '')        + ' ' like '% LTE %'
    or ' ' + isnull(ProductName, '')  + ' ' like '% LT %'  or ' ' + isnull(ProductName, '')  + ' ' like '% LTE %'
    or ' ' + ItemAsListed             + ' ' like '% LT %'  or ' ' + ItemAsListed             + ' ' like '% LTE %'
GO

-- ============================================================
-- Pass 4c -- Normalize ContainerType to lowercase canonical tokens
-- Enables consistent use of AI-extracted ContainerType as a higher-
-- priority signal in the fkContainerId CASE (updateTisFromAI.sql).
-- Rows already holding a canonical value are skipped by the WHERE.
-- ============================================================
update TabX.ImportStagingAI
set ContainerType = lower(trim(
   case
      when lower(trim(ContainerType)) in ('bottle','btle','btl','bot','bottles') then 'bottle'
      when lower(trim(ContainerType)) in ('can','cans','aluminum can','tin') then 'can'
      when lower(trim(ContainerType)) in ('draft','draught','drft','dft','tap','keg','on tap') then 'draft'
      when lower(trim(ContainerType)) in ('glass','wine glass','cocktail glass','pint glass','pint') then 'glass'
      when lower(trim(ContainerType)) in ('shot','single shot','single','sgl') then 'shot'
      when lower(trim(ContainerType)) in ('double','double shot','dbl') then 'double'
      else ContainerType
   end
))
where ContainerType is not null
  and lower(trim(ContainerType)) not in ('bottle','can','draft','glass','shot','double')
GO

-- ============================================================
-- Pass 5 -- Strip trailing size/quantity annotations from ProductName only
-- Brand and ItemAsListed are intentionally excluded; they may legitimately
-- contain sizing (e.g. 'Stella Artois 750ml', 'Corona 12 pack').
-- ImportStagingAI has dedicated ContainerSizeQty/ContainerSizeUnit columns;
-- this pass cleans up cases where the AI left the size appended to ProductName.
-- More specific (longer) trailing patterns are evaluated first.
-- WHERE pre-filter limits the scan to rows likely containing a size annotation.
-- ============================================================
update TabX.ImportStagingAI
set ProductName =
   case
      -- oz, no space before unit
      when ProductName like '% [0-9][0-9][0-9]oz' then left(ProductName, len(ProductName) - 6)
      when ProductName like '% [0-9][0-9]oz'       then left(ProductName, len(ProductName) - 5)
      when ProductName like '% [0-9]oz'             then left(ProductName, len(ProductName) - 4)
      -- oz, space before unit
      when ProductName like '% [0-9][0-9][0-9] oz' then left(ProductName, len(ProductName) - 7)
      when ProductName like '% [0-9][0-9] oz'       then left(ProductName, len(ProductName) - 6)
      when ProductName like '% [0-9] oz'             then left(ProductName, len(ProductName) - 5)
      -- ml, no space before unit
      when ProductName like '% [0-9][0-9][0-9]ml'  then left(ProductName, len(ProductName) - 6)
      when ProductName like '% [0-9][0-9]ml'        then left(ProductName, len(ProductName) - 5)
      when ProductName like '% [0-9]ml'              then left(ProductName, len(ProductName) - 4)
      -- ml, space before unit
      when ProductName like '% [0-9][0-9][0-9] ml' then left(ProductName, len(ProductName) - 7)
      when ProductName like '% [0-9][0-9] ml'       then left(ProductName, len(ProductName) - 6)
      when ProductName like '% [0-9] ml'             then left(ProductName, len(ProductName) - 5)
      -- liter, uppercase L then lowercase l variants (both listed for CS-collation safety)
      when ProductName like '% [0-9].[0-9]L'        then left(ProductName, len(ProductName) - 5)
      when ProductName like '% [0-9]L'               then left(ProductName, len(ProductName) - 3)
      when ProductName like '% [0-9].[0-9]l'        then left(ProductName, len(ProductName) - 5)
      when ProductName like '% [0-9]l'               then left(ProductName, len(ProductName) - 3)
      -- pk, no space before unit
      when ProductName like '% [0-9][0-9]pk'        then left(ProductName, len(ProductName) - 5)
      when ProductName like '% [0-9]pk'              then left(ProductName, len(ProductName) - 4)
      -- pk, space before unit
      when ProductName like '% [0-9][0-9] pk'       then left(ProductName, len(ProductName) - 6)
      when ProductName like '% [0-9] pk'             then left(ProductName, len(ProductName) - 5)
      -- pack, no space before unit
      when ProductName like '% [0-9][0-9]pack'      then left(ProductName, len(ProductName) - 7)
      when ProductName like '% [0-9]pack'            then left(ProductName, len(ProductName) - 6)
      -- pack, space before unit
      when ProductName like '% [0-9][0-9] pack'     then left(ProductName, len(ProductName) - 8)
      when ProductName like '% [0-9] pack'           then left(ProductName, len(ProductName) - 7)
      else ProductName
   end
where ProductName like '% [0-9]%'
GO

-- ============================================================
-- Pass 6 -- Canonicalize AI ProductCategory to TypeDescriptions
-- The AI writes TYPE data into the ProductCategory column (column
-- swap at source).  The update script reads it as isai_d.ProductType
-- and matches it against Common.ProductTypes.TypeDescription.
-- This pass maps the AI's sub-type values to the canonical parent
-- TypeDescription so the cpt OUTER APPLY gets an exact match rather
-- than relying on substring fallbacks (which cannot bridge unrelated
-- terms, e.g. 'IPA' → 'Beer', 'Bourbon' → 'Liquor').
--
-- The WHERE excludes rows already holding a canonical value.
-- To add new mappings: extend the appropriate WHEN block and, if the
-- AI could ever return the new canonical value directly, add it to
-- the WHERE NOT IN list too.
-- ============================================================
update TabX.ImportStagingAI
set ProductCategory =
   case
      -- ── Beer ──────────────────────────────────────────────
      when lower(trim(ProductCategory)) in (
         'pilsner and pale lager','india pale ale (ipa)','ipa','pale ale',
         'wheat beer','porter/stout','porter','stout','dark ale','brown ale',
         'dark lager','wild/sour beer','sour beer','specialty beer',
         'lager','pilsner','pilsner/lager','amber ale','session beer',
         'light beer','domestic beer','import beer','craft beer',
         'cream ale','saison','hefeweizen','kolsch','kolsch','belgian ale',
         'blonde ale','golden ale','golden lager',
         'weizen','dunkel','rauchbier','gose','berliner weisse','witbier',
         'tripel','dubbel','quadrupel','bock','doppelbock','marzen',
         'oktoberfest','altbier','kellerbier','steam beer',
         'american lager','american ale','farmhouse ale','fruit beer',
         'double ipa','imperial ipa','west coast ipa','hazy ipa',
         'new england ipa','neipa','red ipa','black ipa','milkshake ipa',
         'brut ipa','session ipa','imperial stout','pastry stout',
         'oatmeal stout','dry stout','coffee stout','chocolate stout',
         'smoked porter','robust porter','nitro beer','low-carb beer',
         'gluten-free beer','non-alcoholic beer','seasonal beer',
         'pumpkin beer','winter beer','shandy','radler'
      ) then 'Beer'

      -- ── Liquor ────────────────────────────────────────────
      when lower(trim(ProductCategory)) in (
         'bourbon','whiskey','whisky','american whiskey','tennessee whiskey',
         'japanese whisky','japanese whiskey','irish whiskey','canadian whisky',
         'scotch whisky','scotch','single malt scotch','blended scotch',
         'single malt','blended whisky','blended whiskey','rye','rye whiskey',
         'misc whiskey','wheated bourbon','high rye bourbon','corn whiskey',
         'moonshine','straight bourbon','blended bourbon',
         'kentucky straight bourbon','small batch bourbon','single barrel bourbon',
         'cask strength bourbon','malt whiskey','pot still whiskey',
         'peated scotch','peated whisky','islay scotch','highland scotch',
         'speyside scotch','lowland scotch',
         'vodka','non-flavored vodka','flavored vodka',
         'gin','non-flavored gin','flavored gin','london dry gin','old tom gin',
         'sloe gin','genever','jenever','botanical spirit',
         'tequila','blanco tequila','silver tequila','gold tequila',
         'reposado tequila','anejo tequila','extra anejo tequila','anejo',
         'mezcal',
         'rum','light rum','dark rum','white rum','spiced rum','aged rum',
         'flavored rum','overproof rum','rhum agricole',
         'brandy','cognac','armagnac','pisco','cachaca','grappa','slivovitz',
         'grain alcohol','neutral spirit','grain spirit','malt spirit',
         'liqueurs & cordials','liqueur','cordial','schnapps','triple sec',
         'absinthe','amaretto','aquavit','flavored whiskey',
         'coffee liqueur','cream liqueur','herbal liqueur',
         'sake','shochu','baijiu','arak','ouzo','sambuca','limoncello',
         'spirit','spirits','distilled spirits','distilled beverage'
      ) then 'Liquor'

      -- ── Wine ──────────────────────────────────────────────
      when lower(trim(ProductCategory)) in (
         'red wine','white wine','sparkling wine','rose wine',
         'rose','rice wine','champagne','prosecco','cava',
         'merlot','cabernet','cabernet sauvignon','chardonnay',
         'pinot noir','pinot grigio','pinot gris','sauvignon blanc',
         'riesling','zinfandel','syrah','shiraz','malbec',
         'gewurztraminer','viognier','albarino','gruner veltliner',
         'tempranillo','garnacha','grenache','nebbiolo','barolo',
         'barbaresco','chianti','montepulciano','sangiovese',
         'brunello','amarone','valpolicella','moscato','muscat',
         'dessert wine','late harvest','botrytis','sauternes',
         'port','sherry','ice wine','madeira','marsala',
         'vermouth','dry vermouth','sweet vermouth',
         'natural wine','orange wine','lambrusco','sangria',
         'mulled wine','table wine','house wine','wine cooler',
         'white zinfandel','dry wine','off-dry wine','sweet wine',
         'fortified wine','sparkling rose','dry rose'
      ) then 'Wine'

      -- ── RTD / Seltzer ─────────────────────────────────────
      when lower(trim(ProductCategory)) in (
         'hard seltzer','seltzer','spiked seltzer','alcoholic seltzer',
         'craft seltzer','hard sparkling water','spiked water',
         'hard cider','cider',
         'hard iced tea','hard tea',
         'hard lemonade','spiked lemonade',
         'hard kombucha','hard ginger beer',
         'ready to drink cocktails','ready-to-drink','ready to drink','rtd',
         'flavored malt beverage','fmb','malt beverage','alcopop',
         'wine seltzer','malt cooler','cooler',
         'canned cocktail','canned wine',
         'hard coffee','spiked coffee','session rtd'
      ) then 'RTD/Seltzer'

      -- ── Mixed Drink ───────────────────────────────────────
      when lower(trim(ProductCategory)) in (
         'cocktail','cocktails','mixed cocktail','craft cocktail',
         'classic cocktail','signature cocktail','house cocktail',
         'mocktail','virgin cocktail','spirit-free cocktail',
         'frozen drink','frozen cocktail','blended drink',
         'punch','shooter','shot drink'
      ) then 'Mixed Drink'

      -- ── Food ──────────────────────────────────────────────
      when lower(trim(ProductCategory)) in (
         'food item','foods','food & beverage','food and beverage',
         'snack','snacks','appetizer','appetizers','entree',
         'dessert','desserts','side','sides','main course','main',
         'breakfast','lunch','dinner','brunch','bar food','pub food',
         'small plate','small plates','pizza','burger','sandwich',
         'salad','soup','taco','wings','nachos','fries','finger food'
      ) then 'Food'

      -- ── Non-Alcoholic ─────────────────────────────────────
      when lower(trim(ProductCategory)) in (
         'non-alcoholic','non alcoholic','non-alc','nonalcoholic','na drink',
         'soft drink','soda','pop','fountain drink',
         'juice','fruit juice','orange juice','cranberry juice','apple juice',
         'sparkling water','still water','flavored water','infused water',
         'lemonade','iced tea','tea','hot tea','coffee','hot chocolate',
         'milk','smoothie','shake','milkshake',
         'sports drink','electrolyte drink','kombucha',
         'tonic','club soda','ginger ale','cola','diet soda',
         'coconut water','mineral water','spring water'
      ) then 'Non-Alcoholic'

      -- ── Energy Drink ──────────────────────────────────────
      when lower(trim(ProductCategory)) in (
         'energy drink','energy','energy beverage','energy shot',
         '5 hour energy','caffeinated beverage','caffeinated drink',
         'stimulant drink','pre-workout drink','functional drink'
      ) then 'Energy Drink'

      -- ── Mixers ────────────────────────────────────────────
      when lower(trim(ProductCategory)) in (
         'mixer','mixers','cocktail mixer','bar mixer',
         'bitters','simple syrup','grenadine','falernum',
         'lime juice','lemon juice','sour mix','sweet and sour',
         'bloody mary mix','margarita mix','daiquiri mix',
         'orgeat','shrub','tincture','syrup','bar syrup',
         'coconut cream','cream of coconut','pineapple juice'
      ) then 'Mixers'

      -- ── Water ─────────────────────────────────────────────
      when lower(trim(ProductCategory)) in (
         'water','bottled water','alkaline water',
         'tonic water','soda water','club soda water'
      ) then 'Water'

      -- ── Garnish ───────────────────────────────────────────
      when lower(trim(ProductCategory)) in (
         'garnish','garnishes','bar garnish',
         'lime','lemon','orange','cherry','olive','pickle',
         'mint','herb','sprig','rim salt','tajin','sugar rim',
         'celery','cucumber','jalapeno'
      ) then 'Garnish'

      -- ── Merch ─────────────────────────────────────────────
      when lower(trim(ProductCategory)) in (
         'merchandise','apparel','clothing','t-shirt','hat',
         'cap','hoodie','sweatshirt','jacket','bag','gift card',
         'logo item','branded item','souvenir'
      ) then 'Merch'

      -- ── Misc (catch-all for ambiguous or unclassifiable) ──
      when lower(trim(ProductCategory)) in (
         'flavored',
         'other drink',
         'other',
         'unspecified',
         'alcoholic beverage',
         'beverage',
         'drink'
      ) then 'Misc'

      else ProductCategory
   end
where ProductCategory is not null
  and lower(trim(ProductCategory)) not in (
      -- Already canonical TypeDescriptions — skip these rows (no-op guard)
      'beer','liquor','wine','mixed drink','undefined','food','misc',
      'energy drink','non-alcoholic','non-alcoholic drink','non-alc',
      'mixers','merch','water','rtd/seltzer','garnish','thc / cbd'
  )
GO

from dotenv import load_dotenv
load_dotenv(r"C:\dev\Tabx\SQL\vibemap2\vm20260525\.env")

import ssl, httpx, anthropic

# Approach 1: truststore (uses Windows cert store directly)
http_client = None
try:
    import truststore
    ctx = truststore.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    http_client = httpx.Client(verify=ctx)
    print("Using truststore SSL context")
except ImportError:
    print("truststore not installed — pip install truststore to use this approach")
except Exception as e:
    print(f"truststore failed: {e}")

# Approach 2: SSL_CERT_FILE env var (set in .env or environment)
import os
cert_file = os.getenv("SSL_CERT_FILE")
if http_client is None and cert_file:
    http_client = httpx.Client(verify=cert_file)
    print(f"Using SSL_CERT_FILE: {cert_file}")

if http_client is None:
    print("No custom SSL context — using default (will likely fail on corporate network)")

c = anthropic.Anthropic(
    **({"http_client": http_client} if http_client else {})
)
r = c.messages.create(
    model="claude-haiku-4-5-20251001",
    max_tokens=10,
    messages=[{"role": "user", "content": "hi"}]
)
print(r.content)

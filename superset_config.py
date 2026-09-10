import os

# -----------------------------
# Security
# -----------------------------
SECRET_KEY = os.environ.get("SUPERSET_SECRET_KEY", "changeme")

TALISMAN_ENABLED = False

TALISMAN_CONFIG = {
    "force_https": False,
    "force_https_permanent": False,
    "session_cookie_secure": False,
    "content_security_policy": {
        "default-src": ["'self'"],
        "img-src": ["'self'", "data:", "blob:"],
        "script-src": ["'self'", "'unsafe-inline'", "'unsafe-eval'"],
        "style-src": ["'self'", "'unsafe-inline'"],
        "frame-ancestors": ["'self'"],
    },
}

# -----------------------------
# Database
# -----------------------------
DB_USER = os.environ.get("POSTGRES_USER", "superset")
DB_PASSWORD = os.environ.get("POSTGRES_PASSWORD", "changeme")
DB_HOST = os.environ.get("POSTGRES_HOST", "postgres")
DB_NAME = os.environ.get("POSTGRES_DB", "superset")

SQLALCHEMY_DATABASE_URI = (
    f"postgresql+psycopg2://{DB_USER}:{DB_PASSWORD}@{DB_HOST}/{DB_NAME}"
)

# -----------------------------
# Redis
# -----------------------------
REDIS_HOST = os.environ.get("REDIS_HOST", "redis")
REDIS_PORT = int(os.environ.get("REDIS_PORT", 6379))
REDIS_PASSWORD = os.environ.get("REDIS_PASSWORD", "changeme")

# -----------------------------
# Cache
# -----------------------------
CACHE_CONFIG = {
    "CACHE_TYPE": "RedisCache",
    "CACHE_DEFAULT_TIMEOUT": 300,
    "CACHE_KEY_PREFIX": "superset_",
    "CACHE_REDIS_HOST": REDIS_HOST,
    "CACHE_REDIS_PORT": REDIS_PORT,
    "CACHE_REDIS_PASSWORD": REDIS_PASSWORD,
    "CACHE_REDIS_DB": 3,
}

# -----------------------------
# Celery
# -----------------------------
CELERY_BROKER_URL = f"redis://:{REDIS_PASSWORD}@{REDIS_HOST}:{REDIS_PORT}/0"
CELERY_RESULT_BACKEND = CELERY_BROKER_URL

# -----------------------------
# Superset limits
# -----------------------------
ROW_LIMIT = 5000

# -----------------------------
# Gunicorn
# -----------------------------
GUNICORN_TIMEOUT = 60

# MCP development configuration
MCP_AUTH_ENABLED = False
MCP_DEV_USERNAME = "admin"
MCP_SERVICE_HOST = "0.0.0.0"
MCP_SERVICE_PORT = 5008
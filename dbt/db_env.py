"""Turn DATABASE_URL into the variables profiles.yml expects.

dbt's postgres profile needs host, user, password... as separate fields,
while the pipeline keeps a single DATABASE_URL. This script splits it, so
there is still only one secret to manage.

Local (from the repo root):  eval "$(python dbt/db_env.py)"
GitHub Actions:              python dbt/db_env.py --github
"""
import os
import shlex
import sys
from urllib.parse import unquote, urlparse

from dotenv import load_dotenv

load_dotenv()  # reads the repo's .env when run locally; no-op in GitHub Actions
url = urlparse(os.environ["DATABASE_URL"])

values = {
    "DBT_HOST": url.hostname,
    "DBT_PORT": str(url.port or 5432),
    "DBT_USER": unquote(url.username),
    "DBT_ENV_SECRET_PASSWORD": unquote(url.password),
    "DBT_DBNAME": url.path.lstrip("/") or "postgres",
}

if "--github" in sys.argv:
    # The password is only part of the DATABASE_URL secret, so GitHub would not
    # hide it on its own: mask it explicitly before it reaches the environment.
    print(f"::add-mask::{values['DBT_ENV_SECRET_PASSWORD']}")
    with open(os.environ["GITHUB_ENV"], "a") as env_file:
        for key, value in values.items():
            env_file.write(f"{key}={value}\n")
else:
    for key, value in values.items():
        print(f"export {key}={shlex.quote(value)}")

# Paperless Recovery

This guide restores a Paperless-ngx instance from an exported Paperless backup.

## Preconditions

Before starting:

* Stop any existing Paperless stack, *including database volumes*
```bash
cd ~/paperless
docker compose down --volumes
```

* empty all other `/media/paperless-data/*` directories
```bash
ls /media/paperless-data/
rm -rf /media/paperless-data/consume/*
rm -rf /media/paperless-data/data/*
rm -rf /media/paperless-data/media/*
```

## Recovery Steps

* Restore the export directory contents into `/media/paperless-data/export`
* Inspect `metadata.json` for the Paperless version that created the export
* Set `add_paperless_image` to a matching image tag instead of `latest`

Example:
```yaml
add_paperless_image: ghcr.io/paperless-ngx/paperless-ngx:2.15.3
```

* Start the matching Paperless version.
```bash
cd ~/paperless
docker compose pull
docker compose up -d
```

* Complete the first-start user-initialization in the web UI.

Otherwise, the importer fails on an uninitialized database with an error like
`psycopg.errors.UndefinedTable: relation "auth_user" does not exist`

* Run the import.
```bash
docker exec paperless-webserver-1 document_importer ../export
```

* Verify the imported content in the UI.


## Update After Import

Once the import is confirmed:

1. change `add_paperless_image` back to the desired newer version
2. run `docker compose down / pull / up`
3. let Paperless perform the upgrade and migrations

## Troubleshooting

If import fails with `relation "auth_user" does not exist`:

- the database has not been initialized yet
- start the stack and complete the initial Paperless setup in the web UI first

If the web container crashes on startup with `usermod: Permission denied`:

- do not force a Compose `user:` override for the `webserver` service
- let Paperless start as designed and use `USERMAP_UID` / `USERMAP_GID`

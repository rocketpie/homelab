Implemented the unification around apps/restic-client/ and rewired the repo to use it.

Key changes:

* Added the shared app files in apps/restic-client/: restic-client.ps1, schema, and example config.
* Added the reusable add_powershell role and turned playbooks/add-pwsh-ubuntu.yml into a thin wrapper.
* Reworked add_restic_client to install upstream restic, render one JSON config, install the shared PowerShell runtime, and create snapshot/retention systemd units only when some repo allows them.
* Updated playbooks/add-rest-server.yml to use add_restic_client directly and removed add_restic_retention.
* Migrated dockerhost2 and restic1 host vars to the explicit snapshot_allowed / restore_allowed / forget_allowed schema and the new add_restic_client_repository_secrets name.
* Expanded test_restic_server to validate the generated restic-client config, run restic-client.ps1 -ShowStatus, and warn about inventory/config inconsistencies.
* Added user-run test entrypoints in scripts/test/.
* Moved docs to the new model, folded “adding a client repo” into context/guides/restic-client-role.md, and removed the old context/restic-client runtime files.

Local validation:

* git diff --check is clean apart from line-ending warnings.
* PowerShell syntax checks passed for the new scripts/test/*.ps1.
* pwsh -File apps/restic-client/restic-client.ps1 -ConfigPath apps/restic-client/restic-client.example.json -ShowStatus ran successfully.
I did not run the Ansible/playbook-level tests or the new manual scripts/test/* entrypoints, per your instruction. The next ones for you to run are:

* scripts/test/Test-ResticClientInventory.ps1
* scripts/test/Test-ResticClientGeneratedConfig.ps1
* scripts/test/Test-ResticClientRepositoryProbe.ps1

Recommended commit message: refactor restic client into shared pwsh app with explicit repo capabilities


 ./scripts/test/Test-ResticClientInventory.ps1
Running playbooks/test-restic-server.yml for inventory consistency warnings...
Test-ResticClientInventory.ps1: A positional parameter cannot be found that accepts argument '--limit'.

./scripts/test/Test-ResticClientGeneratedConfig.ps1
ERROR! Attempting to decrypt but no vault secrets found

./scripts/test/Test-ResticClientRepositoryProbe.ps1
Running optional repository probe for restic-server-test-repo1...
Test-ResticClientRepositoryProbe.ps1: A positional parameter cannot be found that accepts argument '--limit'.

also, i'd prefer add_restic_client_repositories to be a multiline with the correct json directly,
instead of templating this content into json during deployment

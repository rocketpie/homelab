# VPN Gateway Setup
- add_firewall once: extract fail2ban bantimes from current config -> defaults
- add_firewall task says 
    'Allow HTTP and HTTPS TCP ports through the firewall' and 
    'Allow HTTP/3 and other configured UDP ports through the firewall'
    etc. 
    BUT: the actual ports come from defaults, may not translate to HTTP, HTTPS, HTTP/3
- add_vpn_gateway update to latest: wg-easy (15.4?), caddy (2.11.7?)
- add_vpn_gateway 'Assert vpn_gateway route hostnames are unique' - smells config validation - which should be build-time, not runtime. check.
- add_website defaults add_website_publish_bind see comment
- add_website tasks Copy website content from the Ansible controller missing content deploy strategy
- inventory/host_vars/vserver1 rename? verify content

# long-term image update strategy?

# Dev Container
- how to handle ansible ssh key? vault files?
- move venv-requirements.txt collection-requirements.txt to .devcontainer?
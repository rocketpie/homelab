# Homelab Network Map

## `192.168.178.0/24` Private LAN
- host `192.168.178.1` 'fritz.box' +gateway

- reserved `192.168.178.2` - `192.168.178.19` 'PXE'
- host `192.168.178.6` 'n2'
- host `192.168.178.5` 'n5'

- dhcp `192.168.178.20` - `192.168.178.191`
- host `192.168.178.55` 'dockerhost1' +legacy


## `192.168.178.192/26` Homelab
- host `192.168.178.193` ' netcontroller1'
- host `192.168.178.194` ' netcontroller2'
- host `192.168.178.195` 'restic1'
- host `192.168.178.195` 'restic1'


## `192.168.179.0/24` Public WLAN
- dhcp `192.168.179.0/24` 


## `10.13.0.0/24` VPN overlay
- ip `10.13.0.3` 'gateway'
- ip `10.13.0.6` 'dockerhost1'

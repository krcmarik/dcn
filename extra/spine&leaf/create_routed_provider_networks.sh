openstack network create --share --provider-physical-network datacentre --provider-network-type flat --external public
openstack network segment list --network public | grep None | cut -d' ' -f2 | xargs openstack network segment set --name segment1
openstack network segment create --physical-network leaf1   --network-type flat --network public segment2
openstack network segment create --physical-network leaf2   --network-type flat --network public segment3
openstack subnet create   --network public --network-segment segment1   --ip-version 4 --subnet-range 192.168.122.0/24 --allocation-pool start=192.168.122.200,end=192.168.122.250 segment1
openstack subnet create   --network public --network-segment segment2   --ip-version 4 --subnet-range 192.168.133.0/24 --allocation-pool start=192.168.133.200,end=192.168.133.250 segment2
openstack subnet create   --network public --network-segment segment3   --ip-version 4 --subnet-range 192.168.144.0/24 --allocation-pool start=192.168.144.200,end=192.168.144.250 segment3

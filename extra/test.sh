#!/usr/bin/env bash
# Import an image into the default and AZn locations
# Boot an instance and create a volume in the default location
# Boot an instance and create a volume in the AZn location
# -------------------------------------------------------
# VARS
OVERVIEW=0
GLANCE_SANITY=0
GLANCE_DEL=0
MULTI_GLANCE=0
CINDER_DEL=0
CINDER=0
VOL_FROM_IMAGE=0
CINDER_AZN=0
NOVA_CONTROL_LOGS=0
NOVA_COMPUTE_LOGS=0
PRINET=0
VM_DEL=0
VM=0
CONSOLE=0
VM_AZN=0
PET=0
PET_AZN=0
CEPH_REPORT=0

# Set "n"
# 1 for AZ1 xor 2 for AZ2
NUM=1
AZ="az${NUM}"

if [ $NUM -eq 1 ]; then
    BEG=3
    END=5
fi
if [ $NUM -eq 2 ]; then
    BEG=6
    END=8
fi

CIR=cirros-0.5.2-x86_64-disk.img
CIR_URL=http://download.cirros-cloud.net/0.5.2/$CIR
IMG_NAME=cirros
VOL_NAME=vol1
VM_NAME=vm1
VOL_IMG_NAME="${VOL_NAME}-${IMG_NAME}"

SSH_OPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# -------------------------------------------------------
# FUNCTIONS

openstack() {
    # Run openstack command inside openstackclient pod
    oc rsh -t --shell='/bin/sh' openstackclient openstack $@
}

glance() {
    # Run glance command inside openstackclient pod
    # From opentsackclient pod's `.config/openstack/clouds.yaml`
    END=https://keystone-public-openstack.apps.ocp.openstack.lab
    oc rsh -t --shell='/bin/sh' openstackclient glance --os-auth-url $END --os-project-name admin --os-username admin --os-password 12345678 --os-user-domain-name default --os-project-domain-name default $@
}

rceph() {
    # "Remote Ceph": run commands on remote ceph clusters
    NULL="2> /dev/null"
    local N="$1"
    local CMD="$2"
    shift
    shift
    if [ $N -eq 0 ]; then
        NODE="compute-0"
        FSID_ARG=""
    else
        # using global $BEG
        NODE="compute-$BEG"
        # They passed $NUM so we use $AZ
        FSID=$(ssh $SSH_OPT $NODE "sudo grep fsid /etc/ceph/$AZ.conf | sed 's/fsid = //'")
        FSID_ARG="--fsid $FSID"
    fi
    echo "Running \"$CMD $@\" on $NODE"
    echo "---"
    ssh $SSH_OPT $NODE "hostname; sudo cephadm shell $FSID_ARG -- $CMD $@ $NULL"
    echo ""
}

# -------------------------------------------------------
# MAIN(s)

export PASS=$(cat ~/.kube/kubeadmin-password)
oc login -u kubeadmin -p $PASS https://api.ocp.openstack.lab:6443
if [[ $? -gt 0 ]]; then
    exit 1
fi

if [ $OVERVIEW -eq 1 ]; then
    openstack endpoint list
    openstack network agent list
    openstack compute service list
    openstack volume service list

    openstack aggregate list
    openstack aggregate show $AZ

    echo "Volume services"
    openstack volume service list
    echo "Volume availability zones"
    openstack availability zone list --volume
fi

if [ $GLANCE_SANITY -eq 1 ]; then
    GLANCE_ENDPOINT=$(openstack endpoint list -f value -c "Service Name" -c "Interface" -c "URL" | grep glance | grep public | awk {'print $3'})
    if [[ $(curl -s $GLANCE_ENDPOINT | grep Unavailable | wc -l) -gt 0 ]]; then
        echo "curl $GLANCE_ENDPOINT returns unavailable (glance broken?)"
        curl -s $GLANCE_ENDPOINT
        exit 1
    fi
    glance image-list
    if [[ $? -gt 0 ]]; then
        echo "Aborting. Not even 'glance image-list' works."
        exit 1
    fi
fi

if [ $GLANCE_DEL -eq 1 ]; then
    echo "Ensuring there are no Glance images"
    glance image-list
    for IMG in $(openstack image list -c ID -f value); do
        # had issue with new lines, so cleaning
        ID=$(echo $IMG | while IFS= read -r line; do echo -n "$line"; done | tr -d '[:space:]')
        openstack image delete $ID
    done
    glance image-list
fi

if [ $MULTI_GLANCE -eq 1 ]; then
    # import an image two the default store and one of the DCN stores
    glance stores-info
    # stage glance image on openstack client pod
    oc rsh -t --shell='/bin/sh' openstackclient stat $CIR > /dev/null 2>&1
    if [ $? -gt 0 ]; then
        oc rsh -t --shell='/bin/sh' openstackclient curl -L $CIR_URL -o $CIR
    fi
    echo "Uploading $CIR to az0 (default)"
    glance image-create \
           --disk-format raw \
           --container-format bare \
           --name $IMG_NAME \
           --file $CIR \
           --store az0
    for IMG in $(openstack image list -c ID -f value); do
        # this loop should only run once, also clean whitespace from the UUID
        ID=$(echo $IMG | while IFS= read -r line; do echo -n "$line"; done | tr -d '[:space:]')
        echo "$CIR should only be on AZ0"
        glance image-show $ID | grep stores
        rceph 0 rbd -p images ls -l
        rceph $NUM rbd -p images ls -l
        echo "Importing $CIR to $AZ"
        glance image-import $ID --stores $AZ --import-method copy-image
        glance image-show $ID | grep stores
        rceph $NUM rbd -p images ls -l
    done
fi

if [ $CINDER_DEL -eq 1 ]; then
    echo "Ensuring there are no Cinder volumes"
    openstack volume list
    for IMG in $(openstack volume list -c ID -f value); do
        # had issue with new lines, so cleaning
        ID=$(echo $IMG | while IFS= read -r line; do echo -n "$line"; done | tr -d '[:space:]')
        openstack volume delete $ID
    done
    openstack volume list
fi

if [ $CINDER -eq 1 ]; then
    echo "DEFAULT"
    echo " --------- Ceph cinder volumes pool --------- "
    rceph 0 rbd -p volumes ls -l
    openstack volume list
    if [ $VOL_FROM_IMAGE -eq 1 ]; then
        echo "Creating 8 GB Cinder volume from $IMG_NAME"
        for IMG in $(openstack image list -c ID -f value); do
            # this loop should only run once, also clean whitespace from the UUID
            ID=$(echo $IMG | while IFS= read -r line; do echo -n "$line"; done | tr -d '[:space:]')
        done
        openstack volume create --size 8 $VOL_IMG_NAME --image $ID
    else
        echo "Creating empty 1 GB Cinder volume"
        openstack volume create --size 1 $VOL_NAME-default
    fi
    sleep 5
    echo "Listing Cinder Ceph Pool and Volume List"
    openstack volume list
    rceph 0 rbd -p volumes ls -l
fi

if [ $CINDER_AZN -eq 1 ]; then
    echo "$AZ"
    echo " --------- Ceph cinder volumes pool --------- "
    rceph $NUM rbd -p volumes ls -l
    openstack volume list
    if [ $VOL_FROM_IMAGE -eq 1 ]; then
        echo "Creating 8 GB Cinder volume from $IMG_NAME"
        for IMG in $(openstack image list -c ID -f value); do
            # this loop should only run once, also clean whitespace from the UUID
            ID=$(echo $IMG | while IFS= read -r line; do echo -n "$line"; done | tr -d '[:space:]')
        done
        openstack volume create --size 8 --availability-zone $AZ ${VOL_IMG_NAME}-${AZ} --image $ID
    else
        echo "Creating empty 1 GB Cinder volume"
        openstack volume create --size 1 --availability-zone $AZ ${VOL_NAME}-${AZ}
    fi
    sleep 5
    echo "Listing Cinder Ceph Pool and Volume List"
    openstack volume list
    rceph $NUM rbd -p volumes ls -l
    if [ $VOL_FROM_IMAGE -eq 1 ]; then
        openstack volume show ${VOL_IMG_NAME}-${AZ} -f value -c status
    else
        openstack volume show ${VOL_NAME}-${AZ} -f value -c status
    fi
    rceph 0 rbd -p volumes ls -l
fi

if [ $NOVA_CONTROL_LOGS -eq 1 ]; then
    oc get pods | grep nova | grep -v controller
    for POD in $(oc get pods | grep nova | grep -v controller | awk {'print $1'}); do
        echo $POD
        echo "~~~"
        oc logs $POD | grep ERROR | grep -v ERROR_FOR_DIVISION_BY_ZERO
        echo "~~~"
    done
fi

if [ $NOVA_COMPUTE_LOGS -eq 1 ]; then
    SSH_CMD=$(ssh compute-0)
    $SSH_CMD "sudo grep ERROR /var/log/containers/nova/nova-compute.log"
    $SSH_CMD "date"
fi

if [ $PRINET -eq 1 ]; then
    openstack network create private --share
    openstack subnet create priv_sub --subnet-range 192.168.0.0/24 --network private
fi

if [ $VM_DEL -eq 1 ]; then
    echo "Ensuring there are no Nova VMs"
    openstack server list
    for IMG in $(openstack server list -c ID -f value); do
        # had issue with new lines, so cleaning
        ID=$(echo $IMG | while IFS= read -r line; do echo -n "$line"; done | tr -d '[:space:]')
        openstack server delete $ID
    done
    openstack server list
fi

if [ $VM -eq 1 ]; then
    FLAV_ID=$(openstack flavor show c1 -f value -c id 2> /dev/null)
    if [[ $? -gt 0 ]]; then
        openstack flavor create c1 --vcpus 1 --ram 256
        FLAV_ID=$(openstack flavor show c1 -f value -c id 2> /dev/null)
    fi
    FLAV_ID=$(echo $FLAV_ID | while IFS= read -r line; do echo -n "$line"; done | tr -d '[:space:]')
    NOVA_ID=$(openstack server show $VM_NAME -f value -c id 2> /dev/null)
    if [[ $? -gt 0 ]]; then
        # CREATE VM
        for IMG in $(openstack image list -c ID -f value); do
            # this loop should only run once, also clean whitespace from the UUID
            IMG_ID=$(echo $IMG | while IFS= read -r line; do echo -n "$line"; done | tr -d '[:space:]')
        done
        echo "Creating VM with image $IMG_ID"
        if [ $VM_AZN -eq 1 ]; then
            openstack server create --flavor c1 --image $IMG_ID --nic net-id=private $VM_NAME
        else
            openstack server create --flavor c1 --image $IMG_ID --nic net-id=private $VM_NAME --availability-zone $AZ
        fi
        NOVA_ID=$(openstack server show $VM_NAME -f value -c id 2> /dev/null)
    fi
    NOVA_ID=$(echo $NOVA_ID | while IFS= read -r line; do echo -n "$line"; done | tr -d '[:space:]')
    openstack server list
    if [[ $(openstack server list -c Status -f value \
                | while IFS= read -r line; do echo -n "$line"; done \
                | tr -d '[:space:]') == "BUILD" ]]; then
        echo "Waiting one 30 seconds for building server to boot"
        sleep 30
    fi
    openstack server list
    rceph 0 rbd -p vms ls -l
fi

if [ $CONSOLE -eq 1 ]; then
    openstack console log show $VM_NAME
fi

if [ $CEPH_REPORT -eq 1 ]; then
    rceph 0 ceph -s
    rceph $NUM ceph -s
    rceph 0 rbd -p images ls -l
    rceph $NUM rbd -p images ls -l

fi

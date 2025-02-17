# lustre-env

This repository provides scripts to set up and manage a Lustre file
system environment. It includes scripts for configuring Lustre,
installing necessary packages, and creating configuration files.

## lustreenv

### Usage
To set up the Lustre environment, run:
```bash
. lustreenv $(pwd)
```

This script sets the LUSTRE_HOME variable, loads aliases, and initializes nvme-utils.

## lustre-setup.sh

### Usage
After sourcing lustreenv (to set necessary environment variables),
use the `lustre-setup` command:

```bash
lustre-setup [-c /path/to/config.yml] <command> [options]
```
**Note:**  
You can pass the `-c /path/to/config.yml` option to specify an alternate
configuration file. If not provided, the script uses the default file located
at `$LUSTRE_HOME/conf/config.yml`.

Available commands include:
- `setup_mgt_mdt` : Create and configure MGS/MDT.
- `setup_ost`     : Create and configure OSTs.
- `start_mgs`     : Mount the MGS.
- `start_mds`     : Mount MDT.
- `start_oss`     : Mount OSS.
- `stop_mgs`      : Unmount the MGS.
- `stop_mds`      : Unmount MDT.
- `stop_oss`      : Unmount OSS.
- `status`        : Display current mount and configuration status.
- `check`         : Verify that no Lustre mounts are active.
- `remove_pools`  : Remove all created pools.

The `lustre-setup.sh` script configures Lustre servers and clients using a YAML configuration file. By default, it loads:
```bash
$LUSTRE_HOME/conf/config.yml
```

## install-server.sh

### Overview
`install-server.sh` installs the required packages for building and running the
Lustre server. It clones the Lustre release repository, builds Debian packages,
and loads the necessary kernel modules.
This script has been tested on Ubuntu 22.04.

To install the Lustre server, execute:
```bash
./install-server.sh
```

## Configuring Your Lustre System

### Creating config.yml
The template file `conf/config.yml.og` contains default settings for your Lustre
configuration. To create a custom configuration file, copy the template to
`conf/config.yml`:
```bash
cp conf/config.yml.og conf/config.yml
```
Then, modify `conf/config.yml` to reflect your system's settings, such as:
- MGT/MDT pool name, device, and server parameters.
- OST pool prefix, size, and device mappings.
- Filesystem name, mount directory, and ZFS block size.

## Initializing NVMe Utility Aliases

After sourcing `lustreenv`, NVMe utility aliases from the `nvme-utils` directory are automatically available. This allows you to run these scripts by simply typing their name (without the `.sh` extension) from any terminal session.

### NVMe Management
The following commands are available after initializing the environment:

```bash
# List NVMe devices and their block devices
find_nvme

# Bind/Unbind NVMe devices
bind_nvme -m {vfio|kernel} [-f /path/to/nvme_devices.yml]

# Check NVMe device status
bind_nvme status [-f /path/to/nvme_devices.yml]
```

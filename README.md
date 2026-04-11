# boring

# nemoclaw on Ubuntu 24


# upload files
1. Dockefile
``` 
openshell sandbox upload my-box Dockerfile /tmp 
```
# known issue
out of docker memory. avoid by following above to get openshell v0.0.26
1. curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | OPENSHELL_VERSION=dev sh
1. curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash

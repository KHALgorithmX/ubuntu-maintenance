# Ubuntu Maintenance Script

A streamlined automation script to keep your Ubuntu system updated, clean, and optimized. This tool simplifies routine maintenance tasks into a single command.

## 🚀 Installation

Follow these steps to clone the repository and integrate the maintenance script into your shell environment.

### 1. Clone the Repository

First, pull the source code to your local machine:

```bash
git clone https://github.com/KHALgorithmX/ubuntu-maintenance.git

```

### 2. Configure Your Shell

Add the script to your `.bashrc` so the maintenance functions are available in every new terminal session:

```bash
echo "source ~/ubuntu-maintenance/maintain.sh" >> ~/.bashrc

```

### 3. Apply Changes

Refresh your current shell to start using the script immediately:

```bash
source ~/.bashrc

```

---

## 🛠️ Usage

Once installed, you can typically run the maintenance routine by typing the command defined in `maintain.sh` (e.g., `maintain` or `update-sys`).

> **Note:** Ensure you have sudo privileges, as system maintenance requires administrative access for updates and cleaning.

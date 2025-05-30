# Portfolio

This repository contains a collection of scripts and tools aimed at automating various IT processes and tasks, particularly in environments utilizing Azure/Microsoft services. Each folder in the repository focuses on a different aspect ranging from Azure Functions to simple PowerShell snippets.

## Folder Structure and Contents

### Ansible

- This folder contains Ansible playbooks. Currently, the one playbook is used to syncronize PowerShell modules up to a Git repo and then sync those back down to multiple automation servers.


### Azure FunctionApp

- This folder contains a PowerShell function app designed to relay SaaS Live Events logs from HTTP to an Azure Log Analytics workspace, providing an integration solution with Azure which was not natively supported by the SaaS.

### Azure Monitor

- Contains Kusto Query Language (KQL) queries used for creating alerts in Azure Monitor and for searching within runbook logs.

### AzureAutomation

- This folder houses various PowerShell runbooks that automate tasks such as email notifications via Microsoft Graph, cleanup of stale Active Directory computers and GPOs, management of compromised accounts, and dynamic IP management for security.
- **Key Tasks Automated**:
  - Alert email notifications (with embedded Log Analytics results).
  - Stale resource cleanup (AD computers, GPOs).
  - Security management for compromised accounts (revoking sessions, removing Exchange ActiveSync devices, removing user's group memberships).
  - Active Directory -> Entra ID ad-hoc synchronization runbook.
  - Synchronizing a VPN IP list to a Conditional Access policies Named Locations to identify and block users whom are using a VPN when trying to authenticate.

### PowerShell

- This directory includes a wide range of PowerShell scripts divided into subfolders for specific purposes including Advent of Code challenges, reusable functions, custom modules, and various snippets.
- **Subfolders**:
  - **Advent of Code 2023**: Scripts for solving Advent of Code 2023 challenges.
  - **Functions**: Reusable pieces of code (exponential back-off retry function, send-email, etc).
  - **Modules**: Custom modules and "sub-modules." HashiCorp Vault module to interact with Vault securely via the API.
  - **Reports**: Scripts designed to compile and generate reports (M365 Product/License Usage).
  - **Snippets**: Small, reusable scripts (creating a scheduled task for a 1-off server reboot at 1 AM, Adding Graph API Permissions, etc)

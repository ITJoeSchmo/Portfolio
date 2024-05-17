# Portfolio

This repository contains a collection of scripts and tools aimed at automating various IT processes and tasks, particularly in environments utilizing Azure/Microsoft services. Each folder in the repository focuses on a different aspect ranging from Azure Functions to PowerShell utilities.

## Folder Structure and Contents

### Azure FunctionApp

- This folder contains a PowerShell function app designed to relay SaaS Live Events logs to Azure Log Analytics (ALA), providing integration solutions not natively supported by Azure.

### Azure Monitor

- Contains Kusto Query Language (KQL) queries used for creating alerts in Azure Monitor and for searching within runbook logs.

### AzureAutomation

- This folder houses various PowerShell runbooks that automate tasks such as email notifications via Microsoft Graph, cleanup of stale Active Directory computers and GPOs, management of compromised accounts, and dynamic IP management for security.
- **Key Tasks Automated**:
  - Email notifications with embedded log results.
  - Stale resource cleanup (AD computers, GPOs).
  - Security management for compromised accounts.
  - Active Directory -> Entra ID ad-hoc synchronization.
  - VPN IP syncing for access control.

### PowerShell

- This directory includes a wide range of PowerShell scripts divided into subfolders for specific purposes including Advent of Code challenges, reusable functions, custom modules, and various snippets.
- **Subfolders**:
  - **Advent of Code 2023**: Scripts for solving Advent of Code 2023 challenges.
  - **Functions**: Reusable pieces of code such as an exponential back-off retry function.
  - **Modules**: Custom HashiCorp Vault module.
  - **Reports**: Scripts designed to compile and generate reports.
  - **Snippets**: Small, reusable scripts like creating scheduled tasks for server reboots.

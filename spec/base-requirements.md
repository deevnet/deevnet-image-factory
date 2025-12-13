# Deevnet Image Factory

The **Deevnet Image Factory** is a unified artifact build system for the Deevnet home and mobile labs (`dvnt` and `dvntm`).  
It produces **automation-ready images and media** from code, using Packer, Ansible, and related tooling.

This repository is responsible for manufacturing *infrastructure artifacts*, not running infrastructure.

---

## Goals

- Build reproducible, automation-ready images from source
- Centralize all image and media builds in one place
- Support multi-pass bootstrapping of dvnt and dvntm
- Minimize manual setup and chicken-and-egg pain
- Favor explicit contracts over implicit system state

---

## Artifact Types

The image factory produces the following first-class artifacts:

1. Proxmox VM templates
2. Raspberry Pi images
3. Bootable ISOs
4. Builder node image (used to run this factory)

---

## Functional Requirements

### FR-1: Image build orchestration
- The factory must use **Packer** as the primary build orchestrator.
- Multiple image types must be supported under one repo and workflow.

---

### FR-2: Proxmox VM template builds
- Build VM templates via:
  - Packer → Proxmox
- Support Ansible provisioning during the Packer build phase.
- Resulting images must be usable as Proxmox templates.

---

### FR-3: Ansible-ready VM templates
VM templates must be “Ansible ready,” meaning:
- SSH enabled
- A bootstrap user or access mechanism exists
- Python installed
- Sudo configured
- Predictable first-boot behavior

Exact enforcement details are defined by provisioning roles.

---

### FR-4: Raspberry Pi image builds
The factory must build multiple Raspberry Pi images, including:
- SDR Pi image
  - Raspberry Pi OS Bookworm 64-bit
  - Based on Jeff Geerling–style workflows
- Music detector Pi image
  - Role-specific Pi image

Pi images must be reproducible from base inputs plus provisioning.

---

### FR-5: Bootstrap node image
- The factory must build a **bootstrap / builder node image** intended for:
  - A small mini PC
  - ~1 TB local storage
- This node must be capable of bootstrapping:
  - dvnt
  - dvntm
- Bootstrapping may require **multiple passes**.

---

### FR-6: Ansible provisioning integration
- Image provisioning must support Ansible playbooks and roles.
- Ansible collections are the extension mechanism.
- `ansible-collection-deevnet.builder` is a core dependency.

---

### FR-7: Multi-pass infrastructure bootstrap support
- The system must assume infrastructure bring-up is staged:
  - Pass 1: core identity, DNS, state, networking
  - Pass 2: compute and platforms
  - Pass 3: services and applications
- Artifacts must support being reused across passes.

---

### FR-8: ISO builds
- The factory must support building **bootable ISOs** as artifacts.
- ISOs may be used for:
  - Unattended installs (Kickstart / autoinstall)
  - Bootstrap media
  - Air-gapped or recovery workflows
- ISO tooling may vary by OS but must be automated and reproducible.

---

### FR-9: Local artifact availability
- The factory assumes artifacts are available via **localhost**.
- The builder node runs:
  - the image factory
  - the artifact service
- Builds may reference artifacts via `http://localhost/...`.

---

### FR-10: Artifact services provided by the builder
The builder node must provide:
- A local HTTP artifact endpoint
- A predictable filesystem layout for artifacts
- Stable URLs for use by Packer and ISO tooling

Provisioning of these services is handled by Ansible collections.

---

### FR-11: Virtualization support on the build host
- The machine running the image factory must support **hardware virtualization**.
- CPU must support VT-x / AMD-V and nested virtualization where required.
- Virtualization must be enabled in firmware (BIOS/UEFI).
- This is required for Packer workflows that:
  - Launch local VMs
  - Perform ISO-based or QEMU/KVM-backed image builds

This requirement applies to the builder node and any host used to run the image factory.

---

### FR-12: High-level Makefile orchestration (non-privileged)
- The repository must include a **high-level Makefile** that provides:
  - Targets to build each artifact type (and/or each specific image target)
  - A target to list all supported build targets
  - A target to list all required dependencies/tooling for builds
- The Makefile **must not attempt to install or modify system dependencies**.
  - It must assume the invoking user may **not** have sudo privileges.
  - It must not run package managers (dnf/apt/yum/pacman/brew) or system updates.
- Dependency reporting should be informational and non-destructive:
  - Detect presence/absence
  - Print versions when available
  - Exit non-zero on missing required tooling for a requested build target

---

## Non-Functional Requirements

### NFR-1: Reproducibility
- Builds should be deterministic given identical inputs.
- Tooling and dependencies must be explicit.

---

### NFR-2: Idempotency
- Ansible provisioning should converge safely when re-run.

---

### NFR-3: Maintainability
- Adding a new image should be obvious.
- Shared logic must be centralized.
- Repo structure should minimize copy/paste.

---

### NFR-4: Portability
- The factory must run on the builder node without fragile assumptions.
- dvnt vs dvntm differences should be parameterized.

---

### NFR-5: Build observability
- Builds must emit useful logs.
- Artifacts must be traceable to:
  - git commit
  - base image
  - build timestamp/version

---

### NFR-6: Bootstrap survivability
- Rebuilding the builder node must be possible with minimal manual steps.
- The system must tolerate “rebuild the forge” scenarios.

---

## Artifact Contract (Conceptual)

- Artifacts are stored on the builder node filesystem.
- Artifacts are served over HTTP from localhost.
- Packer, ISO tooling, and Pi image builds reference artifacts via stable URLs.

Exact paths and URLs are defined by convention.

---

## Notes

- This repo builds artifacts — it does not deploy infrastructure.
- Deployment and runtime automation live in Terraform and Ansible collections.
- The builder node is both:
  - a product of this factory
  - the machine that runs this factory

This recursion is intentional.


#!/usr/bin/python3
"""Build and check the take-home OVA (CHG-0076).

  ova.py build NAME VMDK CAPACITY OUT.ova   write NAME.ovf and NAME.mf, then the OVA
  ova.py check OVA                          check the OVA's order, manifest and descriptor

The OVA is OVF 1.0, as VirtualBox exports it: a 64-bit Debian machine with
2 CPUs, 2 GB of memory, BIOS firmware (VirtualBox's default when the
descriptor names none), the disk on a SATA (AHCI) controller, and one
Intel PRO/1000 adapter connected "Bridged". The disk is the VM image's,
converted unchanged into a stream-optimized VMDK.
"""
import hashlib
import os
import sys
import tarfile
import xml.etree.ElementTree as ET

OVF = "http://schemas.dmtf.org/ovf/envelope/1"
RASD = "http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData"
VSSD = "http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData"
VBOX = "http://www.virtualbox.org/ovf/machine"

CPUS, MEMORY_MB = 2, 2048

DESCRIPTOR = """<?xml version="1.0" encoding="UTF-8"?>
<Envelope ovf:version="1.0" xml:lang="en-US"
    xmlns="{OVF}" xmlns:ovf="{OVF}" xmlns:rasd="{RASD}" xmlns:vssd="{VSSD}"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:vbox="{VBOX}">
  <References>
    <File ovf:id="file1" ovf:href="{disk_file}" ovf:size="{disk_size}"/>
  </References>
  <DiskSection>
    <Info>The take-home backend's disk</Info>
    <Disk ovf:diskId="vmdisk1" ovf:fileRef="file1" ovf:capacity="{capacity}"
        ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"/>
  </DiskSection>
  <NetworkSection>
    <Info>The network the adapter is bridged to</Info>
    <Network ovf:name="Bridged">
      <Description>Bridged to the computer's own network</Description>
    </Network>
  </NetworkSection>
  <VirtualSystem ovf:id="{name}">
    <Info>Deevnet take-home tenant backend</Info>
    <Name>{name}</Name>
    <OperatingSystemSection ovf:id="96">
      <Info>The guest operating system</Info>
      <Description>Debian_64</Description>
      <vbox:OSType ovf:required="false">Debian_64</vbox:OSType>
    </OperatingSystemSection>
    <VirtualHardwareSection>
      <Info>2 CPUs, 2 GB of memory, a SATA disk, a bridged adapter</Info>
      <System>
        <vssd:ElementName>Virtual Hardware Family</vssd:ElementName>
        <vssd:InstanceID>0</vssd:InstanceID>
        <vssd:VirtualSystemIdentifier>{name}</vssd:VirtualSystemIdentifier>
        <vssd:VirtualSystemType>virtualbox-2.2</vssd:VirtualSystemType>
      </System>
      <Item>
        <rasd:Caption>{cpus} virtual CPUs</rasd:Caption>
        <rasd:Description>Number of virtual CPUs</rasd:Description>
        <rasd:ElementName>{cpus} virtual CPUs</rasd:ElementName>
        <rasd:InstanceID>1</rasd:InstanceID>
        <rasd:ResourceType>3</rasd:ResourceType>
        <rasd:VirtualQuantity>{cpus}</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:AllocationUnits>MegaBytes</rasd:AllocationUnits>
        <rasd:Caption>{memory} MB of memory</rasd:Caption>
        <rasd:Description>Memory Size</rasd:Description>
        <rasd:ElementName>{memory} MB of memory</rasd:ElementName>
        <rasd:InstanceID>2</rasd:InstanceID>
        <rasd:ResourceType>4</rasd:ResourceType>
        <rasd:VirtualQuantity>{memory}</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:Address>0</rasd:Address>
        <rasd:Caption>sataController0</rasd:Caption>
        <rasd:Description>SATA Controller</rasd:Description>
        <rasd:ElementName>sataController0</rasd:ElementName>
        <rasd:InstanceID>3</rasd:InstanceID>
        <rasd:ResourceSubType>AHCI</rasd:ResourceSubType>
        <rasd:ResourceType>20</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:AutomaticAllocation>true</rasd:AutomaticAllocation>
        <rasd:Caption>Ethernet adapter on 'Bridged'</rasd:Caption>
        <rasd:Connection>Bridged</rasd:Connection>
        <rasd:ElementName>Ethernet adapter on 'Bridged'</rasd:ElementName>
        <rasd:InstanceID>4</rasd:InstanceID>
        <rasd:ResourceSubType>E1000</rasd:ResourceSubType>
        <rasd:ResourceType>10</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:AddressOnParent>0</rasd:AddressOnParent>
        <rasd:Caption>disk1</rasd:Caption>
        <rasd:Description>Disk Image</rasd:Description>
        <rasd:ElementName>disk1</rasd:ElementName>
        <rasd:HostResource>/disk/vmdisk1</rasd:HostResource>
        <rasd:InstanceID>5</rasd:InstanceID>
        <rasd:Parent>3</rasd:Parent>
        <rasd:ResourceType>17</rasd:ResourceType>
      </Item>
    </VirtualHardwareSection>
  </VirtualSystem>
</Envelope>
"""


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def build(name, vmdk, capacity, out):
    workdir = os.path.dirname(os.path.abspath(out))
    disk_file = f"{name}-disk001.vmdk"
    ovf_path = os.path.join(workdir, f"{name}.ovf")
    mf_path = os.path.join(workdir, f"{name}.mf")
    with open(ovf_path, "w") as f:
        f.write(DESCRIPTOR.format(OVF=OVF, RASD=RASD, VSSD=VSSD, VBOX=VBOX, name=name,
                                  disk_file=disk_file, disk_size=os.path.getsize(vmdk),
                                  capacity=int(capacity), cpus=CPUS, memory=MEMORY_MB))
    with open(mf_path, "w") as f:
        f.write(f"SHA256({name}.ovf)= {sha256(ovf_path)}\n")
        f.write(f"SHA256({disk_file})= {sha256(vmdk)}\n")
    # OVF 1.0: the descriptor first, then the manifest, then the disk; ustar.
    with tarfile.open(out, "w", format=tarfile.USTAR_FORMAT) as t:
        for path, arc in ((ovf_path, f"{name}.ovf"), (mf_path, f"{name}.mf"), (vmdk, disk_file)):
            info = t.gettarinfo(path, arcname=arc)
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mode = 0o644
            with open(path, "rb") as f:
                t.addfile(info, f)
    os.unlink(ovf_path)
    os.unlink(mf_path)


def check(ova):
    problems = []
    with tarfile.open(ova, "r:") as t:
        members = t.getmembers()
        names = [m.name for m in members]
        if len(names) != 3 or not names[0].endswith(".ovf") or not names[1].endswith(".mf"):
            problems.append(f"order: expected .ovf, .mf, disk; found {names}")
        ovf_bytes = t.extractfile(members[0]).read()
        mf = t.extractfile(members[1]).read().decode()
        digests = {}
        for m in members:
            if m.name.endswith(".mf"):
                continue
            h = hashlib.sha256()
            f = t.extractfile(m)
            for block in iter(lambda: f.read(1 << 20), b""):
                h.update(block)
            digests[m.name] = (h.hexdigest(), m.size)
    listed = {}
    for line in mf.splitlines():
        algo_name, digest = line.split("= ")
        listed[algo_name[len("SHA256("):-1]] = digest
    for name, (digest, _) in digests.items():
        if listed.get(name) != digest:
            problems.append(f"manifest: {name} {listed.get(name)} != {digest}")
    if set(listed) != set(digests):
        problems.append(f"manifest lists {sorted(listed)}, OVA holds {sorted(digests)}")
    root = ET.fromstring(ovf_bytes)
    ns = {"ovf": OVF}
    for f in root.findall("ovf:References/ovf:File", ns):
        href = f.get(f"{{{OVF}}}href")
        size = int(f.get(f"{{{OVF}}}size"))
        if href not in digests:
            problems.append(f"descriptor names {href}, not in the OVA")
        elif digests[href][1] != size:
            problems.append(f"descriptor gives {href} {size} bytes, the OVA {digests[href][1]}")
    disk = root.find("ovf:DiskSection/ovf:Disk", ns)
    print(f"descriptor: disk {disk.get(f'{{{OVF}}}fileRef')}, capacity {disk.get(f'{{{OVF}}}capacity')}")
    for p in problems:
        print("FAIL", p)
    if not problems:
        print(f"ok: {', '.join(names)}; manifest matches; descriptor names its disk at its size")
    return 1 if problems else 0


if __name__ == "__main__":
    if len(sys.argv) == 6 and sys.argv[1] == "build":
        build(*sys.argv[2:])
    elif len(sys.argv) == 3 and sys.argv[1] == "check":
        sys.exit(check(sys.argv[2]))
    else:
        sys.exit(__doc__)

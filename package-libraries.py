#!/usr/bin/env python3
"""Copy Homebrew dylib dependencies beside the bundled command-line tools and relocate load paths."""
import hashlib, os, pathlib, re, shutil, subprocess, sys

frameworks = pathlib.Path(sys.argv[-1]).resolve()
binaries = [pathlib.Path(x).resolve() for x in sys.argv[1:-1]]
extra_library_dirs = [pathlib.Path(x).resolve() for x in os.environ.get("HOMEBREW_LIBRARY_PATHS", "").split(os.pathsep) if x]
queue = list(binaries)
seen = set()
rewrites = {}
original_to_bundle = {}

def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True).stdout

def deps(binary):
    out = run("otool", "-L", str(binary))
    return [line.strip().split(" (compatibility",1)[0] for line in out.splitlines()[1:] if " (compatibility" in line]

def rpaths(binary):
    out=run("otool","-l",str(binary)); parts=out.split("cmd LC_RPATH")
    return [p.split("path ",1)[1].split(" (offset",1)[0] for p in parts[1:] if "path " in p]

def resolve(dep, owner):
    candidates=[]
    if dep.startswith("/"): candidates=[pathlib.Path(dep)]
    elif dep.startswith("@loader_path/"): candidates=[owner.parent / dep.removeprefix("@loader_path/")]
    elif dep.startswith("@executable_path/"): candidates=[binaries[0].parent / dep.removeprefix("@executable_path/")]
    elif dep.startswith("@rpath/"):
        tail=dep.removeprefix("@rpath/")
        for rp in rpaths(owner):
            rp=rp.replace("@loader_path",str(owner.parent)).replace("@executable_path",str(binaries[0].parent))
            candidates.append(pathlib.Path(rp)/tail)
        # Copying a Homebrew executable into the app changes @loader_path.
        # Let the packager provide its original library directory as a fallback.
        candidates.extend(directory / pathlib.Path(tail).name for directory in extra_library_dirs)
    for c in candidates:
        if c.exists() and str(c.resolve()).startswith("/opt/homebrew/"): return c.resolve()
    return None

def dest_for(real):
    if real in original_to_bundle:return original_to_bundle[real]
    name=real.name
    dest=frameworks/name
    if dest.exists() and not os.path.samefile(dest,real):
        dest=frameworks/(real.stem+"-"+hashlib.sha1(str(real).encode()).hexdigest()[:8]+real.suffix)
    shutil.copy2(real,dest); os.chmod(dest,0o755)
    original_to_bundle[real]=dest
    queue.append(real)
    return dest

# First pass copies all Homebrew-linked libraries recursively and records per-owner load commands.
while queue:
    owner=queue.pop(0)
    if owner in seen: continue
    seen.add(owner)
    for dep in deps(owner):
        real=resolve(dep,owner)
        if not real: continue
        dest=dest_for(real)
        rewrites.setdefault(owner,{})[dep]=dest.name

# Relocate each library's identity and dependencies to @rpath; system libraries remain system-linked.
for real,dest in list(original_to_bundle.items()):
    ident=run("otool","-D",str(dest)).splitlines()
    if len(ident)>1 and ident[1].strip()!="@rpath/"+dest.name:
        subprocess.run(["install_name_tool","-id","@rpath/"+dest.name,str(dest)],check=True)
for owner, changes in rewrites.items():
    target=original_to_bundle.get(owner,owner)
    for old,name in changes.items():
        subprocess.run(["install_name_tool","-change",old,"@rpath/"+name,str(target)],check=True)
    rp="@loader_path" if owner in original_to_bundle else "@executable_path/../Frameworks"
    existing=rpaths(target)
    if rp not in existing: subprocess.run(["install_name_tool","-add_rpath",rp,str(target)],check=True)

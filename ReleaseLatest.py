"""Saber release tool: build, zip APP/ and publish it as the latest public GitHub release.

Same zip layout as make_release_zip.bat (SaberUpdater only needs the three exes in it):
  SaberLauncher/  Saber.exe SaberFlasher.exe SaberUpdater.exe version.ini assets/ apps/ games/ movies/
Optional: plugins/ (no settings, logs or downloaded covers) and libretro/cores/ (never BIOS or saves).
Publishing uses the GitHub CLI (`gh auth login` once). The tag is the version, as SaberUpdater expects.
"""

import os
import queue
import subprocess
import sys
import threading
import tkinter as tk
import zipfile
from pathlib import Path
from tkinter import messagebox, scrolledtext, ttk

ROOT = Path(__file__).resolve().parent
APP = ROOT / "APP"
DIST = ROOT / "dist"
REPO = "StudioSyndiCatCaius/SaberLauncher"  # same as release.bat / DEFAULT_REPO in Updater/updater.odin

EXES = ["Saber.exe", "SaberFlasher.exe", "SaberUpdater.exe"]
SKIP_ASSETS = {"Ps Vita theme.mp3"}  # personal bgm, as in make_release_zip.bat
SKIP_PLUGIN_EXT = {".ini", ".log"}
SKIP_PLUGIN_DIRS = {"covers"}


def read_version():
    try:
        return (ROOT / "VERSION").read_text().strip()
    except OSError:
        return ""


class Failed(Exception):
    pass


class App:
    def __init__(self, root):
        self.root = root
        self.log_q = queue.Queue()
        self.busy = False
        root.title("Saber Release")
        root.minsize(620, 480)

        frm = ttk.Frame(root, padding=10)
        frm.pack(fill="both", expand=True)

        top = ttk.Frame(frm)
        top.pack(fill="x")
        ttk.Label(top, text="Version:").pack(side="left")
        self.version = tk.StringVar(value=read_version())
        ttk.Entry(top, textvariable=self.version, width=12).pack(side="left", padx=(4, 16))
        ttk.Label(top, text="Repo:").pack(side="left")
        self.repo = tk.StringVar(value=REPO)
        ttk.Entry(top, textvariable=self.repo, width=40).pack(side="left", padx=4, fill="x", expand=True)

        opts = ttk.Frame(frm)
        opts.pack(fill="x", pady=8)
        self.do_build = tk.BooleanVar(value=True)
        self.inc_plugins = tk.BooleanVar(value=False)
        self.inc_cores = tk.BooleanVar(value=False)
        self.replace = tk.BooleanVar(value=False)
        ttk.Checkbutton(opts, text="Build first (release.bat)", variable=self.do_build).grid(row=0, column=0, sticky="w")
        ttk.Checkbutton(opts, text="Include plugins", variable=self.inc_plugins).grid(row=0, column=1, sticky="w", padx=12)
        ttk.Checkbutton(opts, text="Include libretro cores", variable=self.inc_cores).grid(row=0, column=2, sticky="w")
        ttk.Checkbutton(opts, text="Replace release if the tag already exists", variable=self.replace).grid(
            row=1, column=0, columnspan=3, sticky="w")

        ttk.Label(frm, text="Release notes (empty = auto-generated from commits):").pack(anchor="w")
        self.notes = tk.Text(frm, height=5)
        self.notes.pack(fill="x")

        btns = ttk.Frame(frm)
        btns.pack(fill="x", pady=8)
        self.btn_zip = ttk.Button(btns, text="Zip only", command=lambda: self.start(False))
        self.btn_zip.pack(side="left")
        self.btn_pub = ttk.Button(btns, text="Zip + Publish latest", command=lambda: self.start(True))
        self.btn_pub.pack(side="left", padx=8)
        ttk.Button(btns, text="Open dist", command=self.open_dist).pack(side="left")
        self.status = ttk.Label(btns, text="")
        self.status.pack(side="right")

        self.out = scrolledtext.ScrolledText(frm, height=14, state="disabled", font=("Consolas", 9))
        self.out.pack(fill="both", expand=True)

        root.after(100, self.pump)
        threading.Thread(target=self.check_gh, daemon=True).start()

    # ---- log -------------------------------------------------------------

    def log(self, text):
        self.log_q.put(text)

    def pump(self):
        while not self.log_q.empty():
            item = self.log_q.get()
            if isinstance(item, tuple):  # ("done", status text)
                self.set_busy(False, item[1])
                continue
            self.out.configure(state="normal")
            self.out.insert("end", item.rstrip("\n") + "\n")
            self.out.see("end")
            self.out.configure(state="disabled")
        self.root.after(100, self.pump)

    def set_busy(self, busy, status=""):
        self.busy = busy
        state = "disabled" if busy else "normal"
        self.btn_zip.configure(state=state)
        self.btn_pub.configure(state=state)
        self.status.configure(text=status)

    # ---- actions ---------------------------------------------------------

    def check_gh(self):
        try:
            r = subprocess.run(["gh", "auth", "status"], capture_output=True, text=True, cwd=ROOT)
            if r.returncode != 0:
                self.log("GitHub CLI is not logged in; run `gh auth login` before publishing.")
        except FileNotFoundError:
            self.log("GitHub CLI (gh) not found; install it to publish (https://cli.github.com).")

    def open_dist(self):
        DIST.mkdir(exist_ok=True)
        os.startfile(DIST)

    def start(self, publish):
        if self.busy:
            return
        version = self.version.get().strip()
        if not version:
            messagebox.showerror("Saber Release", "Enter a version.")
            return
        if publish and not messagebox.askyesno(
                "Saber Release", f"Publish {version} as the latest public release of {self.repo.get().strip()}?"):
            return
        cfg = dict(
            version=version,
            repo=self.repo.get().strip(),
            build=self.do_build.get(),
            plugins=self.inc_plugins.get(),
            cores=self.inc_cores.get(),
            replace=self.replace.get(),
            notes=self.notes.get("1.0", "end").strip(),
            publish=publish,
        )
        self.out.configure(state="normal")
        self.out.delete("1.0", "end")
        self.out.configure(state="disabled")
        self.set_busy(True, "Working...")
        threading.Thread(target=self.run, args=(cfg,), daemon=True).start()

    def run(self, cfg):
        try:
            if read_version() != cfg["version"]:
                (ROOT / "VERSION").write_text(cfg["version"] + "\n")
                self.log(f"VERSION -> {cfg['version']}")
            if cfg["build"]:
                self.sh(["cmd", "/c", "release.bat"])
            else:
                (APP / "version.ini").write_text(f"version={cfg['version']}\n")
            zip_path = self.make_zip(cfg)
            if cfg["publish"]:
                self.publish(cfg, zip_path)
            self.log_q.put(("done", "Done"))
        except Failed as e:
            self.log(f"FAILED: {e}")
            self.log_q.put(("done", "Failed"))
        except Exception as e:
            self.log(f"ERROR: {e!r}")
            self.log_q.put(("done", "Failed"))

    def sh(self, cmd, check=True):
        self.log("> " + " ".join(cmd))
        p = subprocess.Popen(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True, errors="replace", creationflags=subprocess.CREATE_NO_WINDOW)
        for line in p.stdout:
            self.log(line)
        p.wait()
        if check and p.returncode != 0:
            raise Failed(f"{cmd[0]} exited with {p.returncode}")
        return p.returncode

    def make_zip(self, cfg):
        for exe in EXES:
            if not (APP / exe).is_file():
                raise Failed(f"APP/{exe} missing (build first)")
        DIST.mkdir(exist_ok=True)
        zip_path = DIST / f"SaberLauncher-v{cfg['version']}.zip"
        self.log(f"Zipping {zip_path.name} ...")
        base = "SaberLauncher/"
        count = 0
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
            for name in EXES + ["version.ini"]:
                z.write(APP / name, base + name)
                count += 1
            for d in ("apps", "games", "movies"):
                z.writestr(base + d + "/", "")
            for f in self.walk(APP / "assets"):
                if f.name not in SKIP_ASSETS:
                    z.write(f, base + f.relative_to(APP).as_posix())
                    count += 1
            if cfg["plugins"]:
                for f in self.walk(APP / "plugins"):
                    rel = f.relative_to(APP / "plugins")
                    if f.suffix.lower() in SKIP_PLUGIN_EXT or SKIP_PLUGIN_DIRS & set(rel.parts[:-1]):
                        continue
                    z.write(f, base + f.relative_to(APP).as_posix())
                    count += 1
            if cfg["cores"]:
                for f in self.walk(APP / "libretro" / "cores"):
                    z.write(f, base + f.relative_to(APP).as_posix())
                    count += 1
        mb = zip_path.stat().st_size / (1024 * 1024)
        self.log(f"Built {zip_path} ({count} files, {mb:.1f} MB)")
        return zip_path

    @staticmethod
    def walk(folder):
        if not folder.is_dir():
            return []
        return sorted(p for p in folder.rglob("*") if p.is_file())

    def publish(self, cfg, zip_path):
        tag, repo = cfg["version"], cfg["repo"]
        exists = subprocess.run(["gh", "release", "view", tag, "--repo", repo], cwd=ROOT, capture_output=True,
                                creationflags=subprocess.CREATE_NO_WINDOW).returncode == 0
        if exists:
            if not cfg["replace"]:
                raise Failed(f"release {tag} already exists (bump the version or tick Replace)")
            self.sh(["gh", "release", "delete", tag, "--repo", repo, "--yes", "--cleanup-tag"])
        cmd = ["gh", "release", "create", tag, str(zip_path), "--repo", repo,
               "--title", f"Saber {tag}", "--latest"]
        cmd += ["--notes", cfg["notes"]] if cfg["notes"] else ["--generate-notes"]
        self.sh(cmd)
        self.log(f"Published {tag}: https://github.com/{repo}/releases/tag/{tag}")


def main():
    if sys.platform != "win32":
        print("Windows only (release.bat).")
    root = tk.Tk()
    App(root)
    root.mainloop()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Verify delivered recipes, using a minimal OpenWrt macro harness (not a build)."""
import pathlib
import re
import subprocess
import sys
import tempfile


def install(recipe, source=None):
    """Execute Package/exiftool/install against synthetic or supplied source."""
    with tempfile.TemporaryDirectory(prefix="exiftool-install-") as directory:
        root = pathlib.Path(directory)
        # Pinned perlver.mk defines PERL_VERSION2=5.40; no cross-build mocked.
        build = pathlib.Path(source) if source else root / "source"
        if not source:
            for name in ["exiftool", "lib/Image/ExifTool.pm", "lib/Image/ExifTool/PNG.pm",
                         "lib/Image/ExifTool/Lang/fr.pm", "lib/Image/ExifTool/Geolocation.dat",
                         "lib/File/RandomAccess.pm", "lib/Image/ExifTool.pod",
                         "lib/Image/ExifTool/README", "t/test.t", "Makefile.PL"]:
                path = build / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("#!/usr/bin/env perl\n" if name == "exiftool" else name)
        dest = root / "dest"
        # Execute the actual macro body, not a separately transcribed installer.
        # This checks layout only, not GNU Make/OpenWrt evaluation or cross-building.
        body = re.search(r'^define Package/exiftool/install\n(.*?)^endef',
                         recipe.read_text(), re.M | re.S)[1]
        substitutions = {"$(1)": str(dest), "$(PKG_BUILD_DIR)": str(build),
                         "$(PERL_VERSION2)": "5.40", "$(INSTALL_DIR)": "mkdir -p",
                         "$(INSTALL_BIN)": "install -m 0755", "$(CP)": "cp -fpR"}
        for variable, value in substitutions.items():
            body = body.replace(variable, value)
        assert "$(" not in body, "unsupported macro in install harness"
        subprocess.run(["bash", "-eu", "-c", body], check=True)
        cli = dest / "usr/bin/exiftool"
        assert cli.stat().st_mode & 0o111
        assert cli.read_text().splitlines()[0] == "#!/usr/bin/perl"
        lib = dest / "usr/lib/perl5/5.40"
        expected = {p.relative_to(build / "lib") for p in (build / "lib").rglob("*")
                    if p.is_file() and p.suffix != ".pod" and p.name != "README"}
        actual = {p.relative_to(lib) for p in lib.rglob("*") if p.is_file()}
        assert expected == actual, (expected - actual, actual - expected)
        assert {p.relative_to(dest).parts[0] for p in dest.rglob("*")} == {"usr"}
        if source:
            env = dict(__import__("os").environ, PERL5LIB=str(lib))
            assert subprocess.check_output([str(cli), "-ver"], env=env, text=True).strip() == "13.59"
            image = root / "smoke.jpg"
            image.write_bytes((build / "t/images/ExifTool.jpg").read_bytes())
            subprocess.run([str(cli), "-overwrite_original", "-Artist=OpenWrt smoke", str(image)], env=env, check=True)
            assert subprocess.check_output([str(cli), "-s3", "-Artist", str(image)], env=env, text=True).strip() == "OpenWrt smoke"
            print(f"HOST SMOKE: version, installed module tree ({len(actual)} files), JPEG metadata write/read passed")


def overlay(script):
    """Execute the delivered copy block and verify ordering against real calls."""
    text = script.read_text()
    block = re.search(r'if \[ -d "\$MCPE_REPO_ROOT/package" \]; then\n.*?\nfi', text, re.S)
    assert block, "missing package overlay block"
    commands = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
    assert commands.index(block[0]) < commands.index('./scripts/feeds update -a') < commands.index('./scripts/feeds install -a') < commands.index('cp "$STAGED_CONFIG" "$CONFIG_FILE"')
    with tempfile.TemporaryDirectory(prefix="exiftool-overlay-") as directory:
        root = pathlib.Path(directory)
        repo, target = root / "repo", root / "openwrt"
        (repo / "package/exiftool/nested").mkdir(parents=True)
        (repo / "package/exiftool/Makefile").write_text("recipe")
        (repo / "package/exiftool/nested/.hidden").write_text("hidden")
        target.mkdir()
        command = f'MCPE_REPO_ROOT="{repo}"; OPENWRT_DIR="{target}";\n{block[0]}'
        subprocess.run(["bash", "-eu", "-c", command], check=True)
        assert (target / "package/exiftool/Makefile").read_text() == "recipe"
        assert (target / "package/exiftool/nested/.hidden").read_text() == "hidden"
        assert not (target / ".config").exists()
        subprocess.run(["bash", "-eu", "-c", command], check=True)
        empty = root / "absent"
        empty.mkdir()
        subprocess.run(["bash", "-eu", "-c", command.replace(str(repo), str(empty))], check=True)


def contract(recipe):
    """Check fixed upstream identity and mandatory split Perl dependencies."""
    text = recipe.read_text()
    for line in ["PKG_NAME:=exiftool", "PKG_VERSION:=13.59", "PKG_SOURCE:=Image-ExifTool-$(PKG_VERSION).tar.gz",
                 "PKG_SOURCE_URL:=https://downloads.sourceforge.net/project/exiftool",
                 "PKG_HASH:=668ea3acececb7235fbd0f4900e72d5f12c9b07e5c778fd36cb1e9b5828fd65a",
                 "PKG_LICENSE:=GPL-1.0-or-later Artistic-1.0-Perl"]:
        assert line in text, line
    deps = re.search(r'^\s*DEPENDS:=(.*)$', text, re.M)[1].split()
    assert set(deps) == {"+perl", "+perlbase-essential", "+perlbase-file", "+perlbase-integer", "+perlbase-time"}, deps
    assert "perlmod/Configure" not in text and "perl/host" not in text


if __name__ == "__main__":
    path = pathlib.Path(sys.argv[1]).resolve()
    if "--overlay" in sys.argv:
        overlay(path)
    elif "--install" in sys.argv:
        install(path, sys.argv[3] if len(sys.argv) > 3 else None)
    else:
        contract(path)

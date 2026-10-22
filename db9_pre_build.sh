#!/usr/bin/env bash
# MiSTer-DB9 CI pre-build step: build the Paprium cartridge MCU firmware
# before the Quartus compile. The fork CI (.github/quartus_build.sh build_leg)
# runs this file when it exists.
#
# Upstream Paprium (V.08, thekoalakoa CPU MATE 0.2.6 merge) no longer commits
# rtl/PAPRIUM/{mcu,mcu_ext,wram_hi,wram_lo}.txt: the images embed the CPU MATE
# brain, which ships only as a release download. Without them Quartus fails
# Error (10054) can't open rtl/PAPRIUM/mcu.txt. Upstream's own
# scripts/build_mcu.sh rebuilds them from public, pinned inputs:
#   - cpu-mate-brain_0.2.6.zip (thekoalakoa/Paprium_MiSTer release 0.2.6)
#   - krikzz/mega-ppm (build_mcu.sh reads its pinned commit via git archive)
#   - xPack riscv-none-elf GCC 15.2.0-1
# With exactly these the images are byte-identical to the 0.2.6 release; the
# build fails unless the installed md5s equal build_mcu.sh KNOWN_release_brain.
#
# Exits 0 when rtl/PAPRIUM/mcu.txt already exists (local builds). Runs on the
# host runner before the Quartus container. Everything it downloads lives under
# ${RUNNER_TEMP:-$HOME}/paprium-fw, outside the work tree, so the source hash
# and git status stay clean.
#
# Bumping the brain or GCC: update the pins below, then dispatch a forced
# rebuild (release.yml -f forced=true). The source hash does not see this
# script, so a pin change alone never rebuilds the RBF.
#
#   bash db9_pre_build.sh          (cwd = repo root)

set -euo pipefail

[[ ! -f rtl/PAPRIUM/mcu.txt ]] || exit 0

# shellcheck source=.github/retry.sh
source .github/retry.sh

BRAIN_URL="https://github.com/thekoalakoa/Paprium_MiSTer/releases/download/0.2.6/cpu-mate-brain_0.2.6.zip"
BRAIN_SHA256=341b3d0cabb996bbcc6c10ccc356c288b528c2934b6620231ef95dbf32159075
GCC_VERSION=15.2.0-1
GCC_TARBALL="xpack-riscv-none-elf-gcc-${GCC_VERSION}-linux-x64.tar.gz"
GCC_URL="https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v${GCC_VERSION}/${GCC_TARBALL}"
# sha256 from xPack's published ${GCC_TARBALL}.sha
GCC_SHA256=aaaa8060c914851a3e5ee1ba82cc3d6f80972f90638a05c6e823a37557a33758
MEGA_PPM_URL="https://github.com/krikzz/mega-ppm.git"

IMGS=(mcu.txt mcu_ext.txt wram_hi.txt wram_lo.txt)

WORK="${RUNNER_TEMP:-${HOME}}/paprium-fw"
GCC_BIN="${WORK}/xpack-riscv-none-elf-gcc-${GCC_VERSION}/bin"
# The toolchain alone is ~1.5 GB extracted; free it before the Quartus leg.
rm -rf "${WORK}"
mkdir -p "${WORK}"
trap 'rm -rf "${WORK}"' EXIT

KNOWN="$(sed -n 's/^KNOWN_release_brain="\(.*\)"$/\1/p' scripts/build_mcu.sh)"
if [[ -z "${KNOWN}" ]]; then
    echo "::error::KNOWN_release_brain not found in scripts/build_mcu.sh" >&2
    exit 1
fi

echo "Downloading CPU MATE brain..."
retry -- curl -fsSL -o "${WORK}/brain.zip" "${BRAIN_URL}"
echo "${BRAIN_SHA256}  ${WORK}/brain.zip" | sha256sum --status -c -
mkdir -p "${WORK}/brain"
unzip -q -j -o "${WORK}/brain.zip" -d "${WORK}/brain"

echo "Downloading ${GCC_TARBALL}..."
retry -- curl -fsSL -o "${WORK}/${GCC_TARBALL}" "${GCC_URL}"
echo "${GCC_SHA256}  ${WORK}/${GCC_TARBALL}" | sha256sum --status -c -
tar -xzf "${WORK}/${GCC_TARBALL}" -C "${WORK}"
rm -f "${WORK}/${GCC_TARBALL}"

retry -- git clone -q --filter=blob:none "${MEGA_PPM_URL}" "${WORK}/mega-ppm"

bash scripts/build_mcu.sh --brain "${WORK}/brain" --mega-ppm "${WORK}/mega-ppm" \
    --gcc-bin "${GCC_BIN}" --out "${WORK}/out"

GOT=""
for f in "${IMGS[@]}"; do
    GOT="${GOT}${GOT:+ }$(md5sum < "rtl/PAPRIUM/${f}" | cut -d' ' -f1)"
done
if [[ "${GOT}" != "${KNOWN}" ]]; then
    echo "::error::Paprium MCU images are not the 0.2.6 release firmware: got '${GOT}', want '${KNOWN}'" >&2
    exit 1
fi
echo "Paprium MCU firmware installed, md5s match the 0.2.6 release images."

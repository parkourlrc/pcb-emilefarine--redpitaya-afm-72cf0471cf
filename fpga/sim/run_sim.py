#!/usr/bin/env python3
"""Run the FPGA testbenches with the Vivado simulator (xvlog, xelab, xsim).

Usage:
    python fpga/sim/run_sim.py                 # every tb_*.sv, exit code 1 on a failure
    python fpga/sim/run_sim.py tb_averager     # one testbench
    python fpga/sim/run_sim.py tb_measure --gui  # open the waveforms in the xsim GUI

Vivado is found through --vivado, then the XILINX_VIVADO variable, then the PATH,
then C:/Xilinx/2025.1/Vivado. Build products go to fpga/sim/out/ (ignored by git).
"""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

SIM_DIR = Path(__file__).resolve().parent
RTL_DIR = SIM_DIR.parent / "rtl"
OUT_DIR = SIM_DIR / "out"
DEFAULT_VIVADO = Path("C:/Xilinx/2025.1/Vivado")
PASS_MARK = "RESULT: PASS"

RTL_SOURCES = [
    "averager.sv",
    "decimator.sv",
    "bram_custom.sv",
    "measure_reg.sv",
    "measure_ctrl.sv",
    "ps_ps_interface_wrapper.sv",
]


def find_tool(name: str, vivado: Path | None) -> str:
    suffix = ".bat" if os.name == "nt" else ""
    roots = [vivado] if vivado else []
    if os.environ.get("XILINX_VIVADO"):
        roots.append(Path(os.environ["XILINX_VIVADO"]))
    for root in roots:
        candidate = root / "bin" / (name + suffix)
        if candidate.is_file():
            return str(candidate)
    on_path = shutil.which(name)
    if on_path:
        return on_path
    candidate = DEFAULT_VIVADO / "bin" / (name + suffix)
    if candidate.is_file():
        return str(candidate)
    sys.exit(f"error: {name} not found; pass --vivado or set XILINX_VIVADO")


def run(cmd: list[str], cwd: Path) -> str:
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    output = result.stdout + result.stderr
    if result.returncode != 0:
        print(output)
        raise RuntimeError(f"{Path(cmd[0]).stem} failed with code {result.returncode}")
    return output


def simulate(bench: str, vivado: Path | None, gui: bool) -> bool:
    work = OUT_DIR / bench
    work.mkdir(parents=True, exist_ok=True)
    sources = [str(RTL_DIR / name) for name in RTL_SOURCES] + [str(SIM_DIR / f"{bench}.sv")]

    run([find_tool("xvlog", vivado), "--sv", *sources], work)
    run([find_tool("xelab", vivado), bench, "-debug", "typical", "-s", f"{bench}_snap"], work)

    xsim = find_tool("xsim", vivado)
    if gui:
        script = work / "waves.tcl"
        script.write_text("log_wave -recursive *\nadd_wave /*\nrun all\n")
        subprocess.run([xsim, f"{bench}_snap", "-gui", "-tclbatch", str(script)], cwd=work)
        return True

    output = run([xsim, f"{bench}_snap", "-R"], work)
    lines = [line for line in output.splitlines() if line.startswith(("FAIL", "RESULT", "---"))]
    lines += [line for line in output.splitlines() if "checks," in line or "generation read" in line]
    for line in lines:
        print(f"  {line}")
    return PASS_MARK in output


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("benches", nargs="*", help="testbench names, default: every tb_*.sv")
    parser.add_argument("--gui", action="store_true", help="open the xsim waveform viewer")
    parser.add_argument("--vivado", type=Path, help="Vivado install folder")
    args = parser.parse_args()

    benches = args.benches or sorted(p.stem for p in SIM_DIR.glob("tb_*.sv"))
    failed = []
    for bench in benches:
        print(f"{bench}:")
        try:
            ok = simulate(bench, args.vivado, args.gui)
        except RuntimeError as error:
            print(f"  {error}")
            ok = False
        if not ok:
            failed.append(bench)
        if not args.gui:
            print(f"  {'passed' if ok else 'FAILED'}")

    if failed:
        print(f"failed: {', '.join(failed)}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

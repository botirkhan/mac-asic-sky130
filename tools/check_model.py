#!/usr/bin/env python3
"""Independent Python re-implementation of the MAC golden model.

Reads a vector file written by model/mac_model.cpp and recomputes every
expected accumulator value with Python's arbitrary-precision integers, then
wraps to AW bits. Any disagreement means the C++ model is wrong, so the RTL is
never judged against a broken reference.

usage: check_model.py <vector_file> [--dw 16] [--guard 8]
"""
import argparse
import sys

ap = argparse.ArgumentParser()
ap.add_argument("vec")
ap.add_argument("--dw", type=int, default=16)
ap.add_argument("--guard", type=int, default=8)
args = ap.parse_args()

AW = 2 * args.dw + args.guard
LO, HI = -(1 << (args.dw - 1)), (1 << (args.dw - 1)) - 1


def wrap(x):
    return ((x + (1 << (AW - 1))) % (1 << AW)) - (1 << (AW - 1))


acc, n, bad, wrapped, vectors = 0, 0, 0, 0, 0
with open(args.vec) as f:
    for line_no, line in enumerate(f, 1):
        first, last, a, b, exp = map(int, line.split())
        if not (LO <= a <= HI and LO <= b <= HI):
            sys.exit(f"line {line_no}: operand out of range")
        raw = a * b if first else acc + a * b
        acc = wrap(raw)
        wrapped += raw != acc
        vectors += last
        n += 1
        if acc != exp:
            bad += 1
            if bad <= 5:
                print(f"line {line_no}: C++ model says {exp}, Python says {acc}")

print(f"check_model: {n} samples, {vectors} dot products, {wrapped} wrapped, {bad} mismatches")
sys.exit(1 if bad else 0)

// -----------------------------------------------------------------------------
// mac_model.cpp -- C++ golden model and test-vector generator for mac_pipe.sv
//
// Usage:
//   mac_model <seed> <out_file> [--dw 16] [--guard 8] [--vectors 300]
//
// Writes one line per input sample:
//     <first> <last> <a> <b> <expected_acc>
// where expected_acc is the value acc_out must show when that sample leaves the
// pipeline. The model is bit-exact: products are full precision and the
// accumulator wraps modulo 2^AW (two's complement), like the RTL.
// -----------------------------------------------------------------------------
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <vector>

struct Sample {
    int first, last;
    int64_t a, b;
};

class MacModel {
public:
    MacModel(int dw, int aw) : dw_(dw), aw_(aw) {}

    // Returns the accumulator value after this sample.
    int64_t step(const Sample& s) {
        int64_t p = s.a * s.b;                    // full-precision product
        acc_ = wrap(s.first ? p : acc_ + p);
        return acc_;
    }

    int64_t min_val() const { return -(int64_t(1) << (dw_ - 1)); }
    int64_t max_val() const { return  (int64_t(1) << (dw_ - 1)) - 1; }

private:
    // Two's-complement wrap of x to aw_ bits (aw_ <= 62).
    int64_t wrap(int64_t x) const {
        const uint64_t mask = (uint64_t(1) << aw_) - 1;
        uint64_t u = uint64_t(x) & mask;
        if (u >> (aw_ - 1)) u |= ~mask;           // sign-extend
        return int64_t(u);
    }

    int dw_, aw_;
    int64_t acc_ = 0;
};

int main(int argc, char** argv) {
    if (argc < 3) {
        std::fprintf(stderr, "usage: %s <seed> <out_file> [--dw N] [--guard N] [--vectors N]\n", argv[0]);
        return 2;
    }
    const unsigned seed = static_cast<unsigned>(std::strtoul(argv[1], nullptr, 10));
    const char* out_path = argv[2];
    int dw = 16, guard = 8, n_random = 300;
    for (int i = 3; i + 1 < argc; i += 2) {
        if      (!std::strcmp(argv[i], "--dw"))      dw       = std::atoi(argv[i + 1]);
        else if (!std::strcmp(argv[i], "--guard"))   guard    = std::atoi(argv[i + 1]);
        else if (!std::strcmp(argv[i], "--vectors")) n_random = std::atoi(argv[i + 1]);
    }
    const int aw = 2 * dw + guard;
    if (dw < 2 || dw > 24 || aw > 62) {
        std::fprintf(stderr, "unsupported widths: dw=%d aw=%d\n", dw, aw);
        return 2;
    }

    MacModel m(dw, aw);
    const int64_t MN = m.min_val(), MX = m.max_val();
    std::mt19937_64 rng(seed);
    auto rnd = [&](int64_t lo, int64_t hi) {
        return std::uniform_int_distribution<int64_t>(lo, hi)(rng);
    };

    std::vector<std::vector<Sample>> vecs;
    auto add_vec = [&](const std::vector<std::pair<int64_t, int64_t>>& ab) {
        std::vector<Sample> v;
        for (size_t i = 0; i < ab.size(); ++i)
            v.push_back({i == 0, i + 1 == ab.size(), ab[i].first, ab[i].second});
        vecs.push_back(v);
    };

    // ---- directed vectors ----
    add_vec({{0, 0}});                                   // zero, single sample
    add_vec({{1, 1}, {2, 3}, {-4, 5}, {7, -8}});         // small mixed signs
    add_vec({{MX, MX}});                                 // max * max
    add_vec({{MN, MN}});                                 // min * min = +2^(2dw-2)
    add_vec({{MN, MX}, {MX, MN}});                       // most negative products
    {   // alternating full-scale signs: partial sums swing +/-
        std::vector<std::pair<int64_t, int64_t>> v;
        for (int i = 0; i < 64; ++i) v.push_back({(i & 1) ? MN : MX, MX});
        add_vec(v);
    }
    {   // headroom: 2^(guard+1)-1 worst-case products, the most that fit in AW bits
        std::vector<std::pair<int64_t, int64_t>> v;
        const int n = (1 << (guard + 1)) - 1;
        for (int i = 0; i < n; ++i) v.push_back({MN, MN});
        add_vec(v);
    }
    {   // same, most negative direction
        std::vector<std::pair<int64_t, int64_t>> v;
        const int n = (1 << (guard + 1));
        for (int i = 0; i < n; ++i) v.push_back({MN, MX});
        add_vec(v);
    }
    {   // one past the limit: must wrap identically in model and RTL
        std::vector<std::pair<int64_t, int64_t>> v;
        const int n = (1 << (guard + 1)) + 1;
        for (int i = 0; i < n; ++i) v.push_back({MN, MN});
        add_vec(v);
    }
    for (int i = 0; i < 16; ++i)                         // back-to-back 1-sample vectors
        add_vec({{rnd(MN, MX), rnd(MN, MX)}});

    // ---- constrained-random vectors ----
    for (int k = 0; k < n_random; ++k) {
        std::vector<std::pair<int64_t, int64_t>> v;
        const int len = (rnd(0, 9) == 0) ? int(rnd(65, 256)) : int(rnd(1, 64));
        const int mode = int(rnd(0, 3));
        for (int i = 0; i < len; ++i) {
            int64_t a, b;
            switch (mode) {
                case 0:  a = rnd(MN, MX); b = rnd(MN, MX); break;            // full range
                case 1:  a = rnd(-8, 8);  b = rnd(-8, 8);  break;            // small values
                case 2:  a = rnd(0, 1) ? MN : MX; b = rnd(0, 1) ? MN : MX;   // corners
                         break;
                default: a = rnd(MN, MX); b = (i & 1) ? MX : MN; break;      // one corner operand
            }
            v.push_back({a, b});
        }
        add_vec(v);
    }

    FILE* f = std::fopen(out_path, "w");
    if (!f) { std::perror(out_path); return 1; }
    size_t n = 0;
    for (const auto& v : vecs)
        for (const auto& s : v) {
            std::fprintf(f, "%d %d %lld %lld %lld\n", s.first, s.last,
                         (long long)s.a, (long long)s.b, (long long)m.step(s));
            ++n;
        }
    std::fclose(f);
    std::printf("mac_model: seed=%u dw=%d aw=%d vectors=%zu samples=%zu -> %s\n",
                seed, dw, aw, vecs.size(), n, out_path);
    return 0;
}

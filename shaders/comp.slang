import bindless;

static const uint CELL_COUNT = 64;
static const uint CELL_MASK  = CELL_COUNT - 1;
static const uint RULE_30    = 0x1E;

struct PC
{
    Ptr<uint> prev;
    Ptr<uint> curr;
}

[shader("compute")]
[numthreads(64, 1, 1)]
void main(
    uint3 index : SV_DispatchThreadID,
    uniform PC pc)
{
    uint i = index.x;

    uint left  = pc.prev[(i - 1) & CELL_MASK];
    uint mid   = pc.prev[i];
    uint right = pc.prev[(i + 1) & CELL_MASK];

    uint pattern = (left << 2) | (mid << 1) | right;

    pc.curr[i] = (RULE_30 >> pattern) & 1;
}
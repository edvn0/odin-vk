import bindless;

struct PC
{
    Ptr<uint> prev;
    Ptr<uint> curr;

    uint width;
    uint height;
    uint image_index;
}

uint cell_index(uint x, uint y, uint width)
{
    return y * width + x;
}

[shader("compute")]
[numthreads(16, 16, 1)]
void main(
    uint3 index : SV_DispatchThreadID,
    uniform PC pc)
{
    uint x = index.x;
    uint y = index.y;

    if (x >= pc.width || y >= pc.height)
        return;

    // Toroidal wraparound: the grid's edges are treated as adjacent.
    uint left = (x + pc.width - 1) % pc.width;
    uint right = (x + 1) % pc.width;
    uint up = (y + pc.height - 1) % pc.height;
    uint down = (y + 1) % pc.height;

    uint neighbors =
        pc.prev[cell_index(left, up, pc.width)] +
        pc.prev[cell_index(x, up, pc.width)] +
        pc.prev[cell_index(right, up, pc.width)] +
        pc.prev[cell_index(left, y, pc.width)] +
        pc.prev[cell_index(right, y, pc.width)] +
        pc.prev[cell_index(left, down, pc.width)] +
        pc.prev[cell_index(x, down, pc.width)] +
        pc.prev[cell_index(right, down, pc.width)];

    uint self = pc.prev[cell_index(x, y, pc.width)];

    // Conway's Game of Life (B3/S23): a dead cell with exactly 3 live
    // neighbors is born; a live cell survives with 2 or 3 live neighbors.
    uint alive = (neighbors == 3 || (self != 0 && neighbors == 2)) ? 1 : 0;

    pc.curr[cell_index(x, y, pc.width)] = alive;

    float value = alive != 0 ? 1.0 : 0.0;

    storage_image_2d[pc.image_index][int2(int(x), int(y))] =
        float4(value, value, value, 1.0);
}

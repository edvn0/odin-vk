struct PC
{
    Ptr<uint> value;
}

[shader("compute")]
void main(uint3 index: SV_DispatchThreadID, uniform PC pc)
{
    uint idx = index.x;
    pc.value[idx] += 1;
}

package config

GRID_WIDTH :: 128
GRID_HEIGHT :: 128

CELL_COUNT :: GRID_WIDTH * GRID_HEIGHT
BUFFER_SIZE :: CELL_COUNT * size_of(u32)

// Game of Life advances one generation every SIM_STEP_INTERVAL seconds of
// accumulated frame time, independent of the render/present rate.
SIM_STEP_INTERVAL :: 0.1
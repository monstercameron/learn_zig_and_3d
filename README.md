# Zig 3D CPU Rasterizer

A complete CPU-based 3D rasterizer built in Zig, featuring real-time rendering, backface culling, flat shading, and interactive controls.

## Features

- **Real-time 3D Rendering**: 120 FPS CPU-based rasterization
- **Perspective Projection**: Proper 3D-to-2D projection with depth
- **Backface Culling**: Efficient culling of hidden triangles
- **Flat Shading**: Directional lighting with brightness calculations
- **Wireframe Rendering**: Optional wireframe overlay with proper culling
- **Interactive Controls**:
  - **Arrow Keys**: Rotate cube (left/right/up/down)
  - **WASD Keys**: Orbit light source
  - **Q/E Keys**: Adjust light distance (closer/farther)
- **Debug Information**: Real-time FPS, brightness statistics, and triangle culling status

## Project Structure

```
├── build.zig           # Build configuration
├── src/
│   ├── main.zig        # Application entry point and event loop
│   ├── renderer.zig    # Core 3D rendering pipeline
│   ├── window.zig      # Windows API window management
│   ├── bitmap.zig      # Pixel buffer management
│   ├── mesh.zig        # 3D mesh data structures
│   └── math.zig        # 3D math operations (vectors, matrices)
└── README.md
```

## Controls

- **Left/Right Arrows**: Rotate cube horizontally
- **Up/Down Arrows**: Rotate cube vertically
- **WASD**: Orbit light source around cube
- **Q**: Move light closer to cube
- **E**: Move light farther from cube

## Building and Running

### Prerequisites
- Zig 0.11 or later
- Windows (uses Windows API)

### Build
```bash
zig build
```

### Run
```bash
zig build run
# or
.\zig-out\bin\zig-windows-app.exe
```

## Technical Details

### Rendering Pipeline
1. **Vertex Transformation**: Apply rotation matrices to 3D vertices
2. **Perspective Projection**: Convert 3D coordinates to 2D screen space
3. **Backface Culling**: Remove triangles facing away from camera
4. **Rasterization**: Fill triangles using scanline algorithm
5. **Lighting**: Calculate brightness based on surface normals and light direction
6. **Wireframe Overlay**: Draw triangle edges on top of filled geometry

### Performance
- **120 FPS** target with frame rate limiting
- **CPU-based**: No GPU acceleration required
- **Efficient algorithms**: Bresenham line drawing, scanline triangle filling
- **Memory managed**: Proper allocation/deallocation of resources

### Architecture
- **Modular design**: Separate concerns across multiple files
- **Windows API**: Direct integration with Win32 for maximum control
- **Error handling**: Comprehensive error checking and recovery
- **Debug logging**: Real-time performance and rendering statistics

## Learning Zig

This project demonstrates advanced Zig concepts:
- **Windows API integration**: Direct FFI calls to user32.dll and gdi32.dll
- **Memory management**: Manual allocation and deallocation
- **Error handling**: Try/catch patterns and error unions
- **Struct composition**: Object-oriented patterns in Zig
- **Performance optimization**: CPU cache-friendly algorithms
- **Real-time systems**: Frame pacing and timing

## Screenshots

The application renders a rotating cube with:
- Smooth flat shading based on light position
- Cyan sphere indicating light source location
- White wireframe edges (only for visible triangles)
- Real-time debug information in console

## Contributing

This is a complete, working 3D rasterizer. For learning purposes, consider:
- Adding texture mapping
- Implementing different shading models
- Adding more complex meshes
- Optimizing for better performance
- Porting to other platforms

## License

This project is open source and available under the MIT License.
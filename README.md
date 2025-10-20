# Zig Windows API Hello World Application# Zig Rasterizer



This is a simple Zig application that demonstrates creating a window using the Windows API, rendering a bitmap, and drawing it to the window.## Overview

The Zig Rasterizer is a CPU-based 3D rasterizer designed with a high-level, tile-based, job-based architecture. It focuses on rendering single triangles efficiently while maintaining clean and modular code.

## Project Structure

## Project Structure

- `build.zig`: The build script that configures the executable and links necessary libraries.```

- `src/main.zig`: The main entry point that initializes the window and renderer, then enters the message loop.zig-rasterizer

- `src/window.zig`: Module for creating and managing the Windows window.├── src

- `src/renderer.zig`: Module for rendering content to a bitmap and drawing it to the window.│   ├── main.zig         # Entry point of the application

- `src/bitmap.zig`: Module for creating and managing device-independent bitmaps.│   ├── rasterizer.zig   # Handles the overall rasterization process

│   ├── tile.zig         # Represents a tile in the rasterization process

## Building and Running│   ├── job.zig          # Represents a job in the job-based architecture

│   └── triangle.zig     # Represents a single triangle to be rasterized

1. Ensure you have Zig installed (version 0.11 or later).├── build.zig            # Build configuration for the Zig project

2. Run `zig build` to build the application.└── README.md            # Documentation for the project

3. Run `zig build run` to build and run the application.```



The application will create a window and display a blue bitmap.## Setup Instructions

1. Ensure you have Zig installed on your system. You can download it from the official Zig website.

## Learning Zig2. Clone the repository or download the project files.

3. Navigate to the project directory.

This project is structured to help learn Zig by:

- Using the Windows API directly for low-level control.## Usage

- Separating concerns into different modules.To build and run the project, use the following command:

- Including detailed comments explaining each part of the code.```

- Demonstrating error handling, memory management, and Windows-specific concepts.zig build run
```

## Architecture
The architecture of the Zig Rasterizer is designed to be modular and efficient:
- **Rasterizer**: Manages the lifecycle of the rasterization process, including initialization, rendering, and shutdown.
- **Tile**: Represents a section of the screen where triangles are drawn, allowing for efficient management of rendering tasks.
- **Job**: Encapsulates the work needed to rasterize a triangle, enabling a job-based approach to processing.
- **Triangle**: Defines the properties of a triangle, including its vertices and methods for calculations necessary for rasterization.

## Design Principles
- **Clean Code**: The project emphasizes readability and maintainability, ensuring that each component is well-defined and easy to understand.
- **Modularity**: Each file and struct is designed to handle a specific aspect of the rasterization process, promoting separation of concerns.
- **Efficiency**: The tile-based and job-based architecture allows for efficient rendering, making the most of CPU resources.

## Contributing
Contributions are welcome! Please feel free to submit issues or pull requests to improve the project.
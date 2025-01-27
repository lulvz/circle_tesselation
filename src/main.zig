const std = @import("std");

const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_opengl.h");
});

const WIDTH = 800;
const HEIGHT = 600;

const CircleGeometry = struct {
    allocator: std.mem.Allocator,

    cx: f32,
    cy: f32,
    radius: f32,

    texture: [*c]c.SDL_Texture,
    vertices: []c.SDL_Vertex,
    indices: []i32,

    const Self = @This();

    // https://www.humus.name/index.php?page=News&ID=228
    pub fn init(allocator: std.mem.Allocator, cx: f32, cy: f32, radius: f32, resolution: usize, color: c.SDL_FColor) !Self {
        const num_vertices: usize = calculateCircumferenceVerticeNum(resolution); 
        const num_indices: usize = calculateCircumferenceIndiceNum(resolution);

        var vertices: []c.SDL_Vertex = try allocator.alloc(c.SDL_Vertex, @intCast(num_vertices));
        const indices: []i32 = try allocator.alloc(i32, @intCast(num_indices));

        const step = (2*std.math.pi) / @as(f32, @floatFromInt(num_vertices));
        var current_step: f32 = 0;

        for(0..num_vertices) |i| {
            vertices[i].position.x = cx + radius*std.math.cos(current_step);
            vertices[i].position.y = cy + radius*std.math.sin(current_step);
            vertices[i].color = color;
            // std.debug.print("{d},{d} at step {d}\n", .{vertices[i].position.x, vertices[i].position.y, current_step});

            current_step -= step;
        }

        indices[0] = 0;
        indices[1] = @intCast(num_vertices/3);
        indices[2] = @intCast(2*num_vertices/3);

        var idx: usize = 3;
        for(1..resolution+1) |resolution_level| {
            // resolution will scale the indices into the VBO like this:
            // resolution 0 -> 1/3
            // resolution 1 -> 1/6
            // resolution 2 -> 1/12
            // resoultion 3 -> 1/24
            const last_resolution = resolution_level - 1;
            const last_denominator = 3 * std.math.pow(usize, 2, last_resolution);

            for(0..last_denominator) |i| {
                const first_vertex_idx = (i*num_vertices/last_denominator);
                const third_vertex_idx = ((((i+1)%last_denominator)*num_vertices))/last_denominator;
                // we find the vertex that is in between the vertices
                const middle_vertex_idx = (first_vertex_idx + (((i+1)*num_vertices)/last_denominator))/2;

                indices[idx] = @intCast(first_vertex_idx);
                indices[idx+1] = @intCast(middle_vertex_idx);
                indices[idx+2] = @intCast(third_vertex_idx);
                
                idx += 3;
            }
        }

        return .{
            .allocator = allocator,
            .cx = cx,
            .cy = cy,
            .radius = radius,
            .texture = null,
            .vertices = vertices,
            .indices = indices,
        };
    }

    // 3 + sum_i_n(3 * 2^(i-1)) -> 3 is the base triangle vertices, then every resolution level we get 1 more vertex per edge
    inline fn calculateCircumferenceVerticeNum(resolution: usize) usize {
        return 3 + 3 * (std.math.pow(usize, 2, resolution)-1);
    }

    // gets the index num at a certain resolution level without the sum of the last levels
    inline fn calculateCircumferenceIndiceNumAtResolution(resolution: usize) usize {
        if(resolution == 0) {
            return 3;
        }
        return 3 * 3 * (std.math.pow(usize, 2, resolution - 1));
    }

    // geometric series implementation
    // 3 + 9*(2^n - 1)
    // which gets simplified to 
    // 9*(2^n) - 6
    inline fn calculateCircumferenceIndiceNum(resolution: usize) usize {
        return 9 * std.math.pow(usize, 2, resolution) - 6;
    }

    pub fn translate(self: *Self, x: f32, y: f32) void {
        self.cx += x;
        self.cy += y;
        for(self.vertices) |*v| {
            v.position.x += x;
            v.position.y += y;
        }
    }

    pub fn renderGeometry(self: *Self, renderer: ?*c.SDL_Renderer) void {
        _ = c.SDL_RenderGeometry(renderer, null, self.vertices.ptr, @intCast(self.vertices.len), self.indices.ptr, @intCast(self.indices.len));
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.vertices);
        self.allocator.free(self.indices);
    }
};

const Player = struct {
    player_geometry: CircleGeometry,
    vx: f32,
    vy: f32,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var running = true;
    if(!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        return error.SDL_InitFailed;
    }
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow("SDL3", WIDTH, HEIGHT, c.SDL_WINDOW_OPENGL);
    if (window == null) return error.WindowCreationFailed;
    defer c.SDL_DestroyWindow(window);

    const renderer = c.SDL_CreateRenderer(window, null);
    if (renderer == null) return error.RendererCreationFailed;
    defer c.SDL_DestroyRenderer(renderer);

    var random = std.rand.DefaultPrng.init(@intCast(std.time.milliTimestamp()));

    const circle_color: c.SDL_FColor = .{
        .r = 1.0,
        .g = 1.0,
        .b = 1.0,
        .a = 1.0,
    };
    var player: Player = .{
        .player_geometry = try CircleGeometry.init(allocator, 100, 100, 50, 10, circle_color),
        .vx = std.rand.float(random.random(), f32)*100+200,
        .vy = std.rand.float(random.random(), f32)*100+200,
    };
    defer player.player_geometry.deinit();

    var trailing_rects: [10]c.SDL_FRect = undefined;

    var event: c.SDL_Event = undefined;

    var counter: f32 = 0;

    var now_time: u64 = c.SDL_GetPerformanceCounter();
    var last_time: u64 = 0;
    var delta_time: f32 = 0;
    while (running) {
        last_time = now_time;
        now_time = c.SDL_GetPerformanceCounter();
        delta_time = @as(f32, @floatFromInt(now_time - last_time)) / @as(f32, @floatFromInt(c.SDL_GetPerformanceFrequency()));

        // INPUT
        while (c.SDL_PollEvent(&event)) {
            if (event.type == c.SDL_EVENT_QUIT) {
                running = false;
            } 
            if (event.type == c.SDL_EVENT_KEY_DOWN) {
                switch (event.key.key) {
                    c.SDLK_ESCAPE => {
                        running = false;
                    },
                    c.SDLK_LEFT => {
                        player.vx += -1;
                    },
                    c.SDLK_RIGHT=> {
                        player.vx += 1;
                    },
                    c.SDLK_UP => {
                        player.vy += -1;
                    },
                    c.SDLK_DOWN => {
                        player.vy += 1;
                    },
                    else => {},
                }
            }
            // if (event.type == c.SDL_EVENT_KEY_UP) {

            // }
        }

        // LOGIC
        const player_vx_dt = player.vx*delta_time;
        const player_vy_dt = player.vy*delta_time;

        player.player_geometry.translate(player_vx_dt, player_vy_dt);

        if(player.player_geometry.cx + player.player_geometry.radius > WIDTH) {
            player.player_geometry.translate(-player_vx_dt, -player_vy_dt);
            player.vx = -player.vx;
        } else if (player.player_geometry.cx - player.player_geometry.radius < 0) {
            player.player_geometry.translate(-player_vx_dt, -player_vy_dt);
            player.vx = -player.vx;
        }
        if(player.player_geometry.cy + player.player_geometry.radius > HEIGHT) {
            player.player_geometry.translate(-player_vx_dt, -player_vy_dt);
            player.vy = -player.vy;
        } else if(player.player_geometry.cy - player.player_geometry.radius < 0) {
            player.player_geometry.translate(-player_vx_dt, -player_vy_dt);
            player.vy = -player.vy;
        }

        counter += delta_time;
        if(counter >= 0.1) {
            // move the existing square to the right
            var i = trailing_rects.len-1;
            while(i > 0) : (i-=1) {
                trailing_rects[i] = trailing_rects[i-1];
            }
            // enq a new square
            trailing_rects[0] = c.SDL_FRect{.x = player.player_geometry.cx, .y = player.player_geometry.cy, .w = 20, .h = 20};

            // std.debug.print("ye\n", .{});
            counter = 0.0;
        }

        // DRAW
        _ = c.SDL_SetRenderDrawColor(renderer, 0x33, 0x33, 0x33, 255);
        _ = c.SDL_RenderClear(renderer);

        _ = c.SDL_SetRenderDrawColor(renderer, 0x16, 0xe3, 0xff, 255);
        _ = c.SDL_RenderFillRects(renderer, &trailing_rects, @intCast(trailing_rects.len));

        player.player_geometry.renderGeometry(renderer);

        _ = c.SDL_RenderPresent(renderer);
    }
}

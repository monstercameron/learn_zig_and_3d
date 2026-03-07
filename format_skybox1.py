import re

def process_file():
    with open("src/renderer.zig", "r", encoding="utf-8") as f:
        text = f.read()

    # 1. Add field to struct
    text = text.replace(
        "    fog_job_contexts: []FogJobContext,\n",
        "    fog_job_contexts: []FogJobContext,\n    skybox_job_contexts: []SkyboxJobContext,\n"
    )

    # 2. Allocate the array
    text = text.replace(
        "        const fog_job_contexts = try allocator.alloc(FogJobContext, color_grade_job_count);\n        errdefer allocator.free(fog_job_contexts);\n",
        "        const fog_job_contexts = try allocator.alloc(FogJobContext, color_grade_job_count);\n        errdefer allocator.free(fog_job_contexts);\n        const skybox_job_contexts = try allocator.alloc(SkyboxJobContext, color_grade_job_count);\n        errdefer allocator.free(skybox_job_contexts);\n"
    )

    # 3. Add to return block
    text = text.replace(
        "            .fog_job_contexts = fog_job_contexts,\n",
        "            .fog_job_contexts = fog_job_contexts,\n            .skybox_job_contexts = skybox_job_contexts,\n"
    )

    # 4. Deallocate
    text = text.replace(
        "        self.allocator.free(self.fog_job_contexts);\n",
        "        self.allocator.free(self.fog_job_contexts);\n        self.allocator.free(self.skybox_job_contexts);\n"
    )

    with open("src/renderer.zig", "w", encoding="utf-8") as f:
        f.write(text)

process_file()

// Authoring example only. Audit actual inputs and build steps before adoption.
// The "jackage" module is a proposed builtin, not an npm install instruction.
import { defineProject, locked, source } from "jackage";

export default defineProject({
  name: "jackage",
  inputs: {
    src: source({
      root: ".",
      include: ["src/**", "build.zig", "build.zig.zon"],
      exclude: [".git/**", ".zig-cache/**", "zig-out/**", ".env*"],
    }),
    zig: locked("zig-0.18.0-dev.146+35accc06e"),
    quickjs: locked("quickjs-ng"),
    transformer: locked("typescript-transformer"),
  },
  tasks: {
    buildLinux: {
      tool: { input: "zig", path: "zig" },
      args: ["build", "-Doptimize=ReleaseSafe"],
      inputs: ["src", "zig", "quickjs", "transformer"],
      outputs: ["zig-out"],
      policy: "release",
      execution: "linux-x86_64",
      output: "linux-x86_64",
    },
  },
  packages: [{ task: "buildLinux", formats: ["tar", "oci"] }],
});

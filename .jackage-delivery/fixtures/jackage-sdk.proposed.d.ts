/** Proposed authoring contract. This is not an installed package or runtime. */
declare module "jackage" {
  export type Platform = "windows-x86_64" | "windows-aarch64"
    | "linux-x86_64" | "linux-aarch64" | "macos-x86_64" | "macos-aarch64";
  export interface LockedInput { readonly kind: "locked"; readonly name: string; }
  export interface SourceInput {
    readonly kind: "source";
    readonly root: string;
    readonly include: readonly string[];
    readonly exclude: readonly string[];
  }
  export interface Task {
    readonly tool: { readonly input: string; readonly path: string };
    readonly args: readonly string[];
    readonly inputs: readonly string[];
    readonly outputs: readonly string[];
    readonly policy: "development" | "release";
    readonly execution: Platform;
    readonly output: Platform;
  }
  export interface Project {
    readonly name: string;
    readonly inputs: Readonly<Record<string, LockedInput | SourceInput>>;
    readonly tasks: Readonly<Record<string, Task>>;
    readonly packages: readonly {
      readonly task: string;
      readonly formats: readonly ("zip" | "tar" | "oci" | "deb" | "rpm" | "msix" | "pkg" | "ext4" | "vhdx")[];
    }[];
  }
  export function locked(name: string): LockedInput;
  export function source(input: Omit<SourceInput, "kind">): SourceInput;
  export function defineProject(project: Project): Project;
}

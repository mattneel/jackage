// Pure constructors. This module has no host bridge or ambient I/O.
export function locked(name) { return Object.freeze({kind: 'locked', name}); }
export function source(input) { return Object.freeze({kind: 'source', root: input.root, include: input.include, exclude: input.exclude}); }
export function defineProject(project) { return project; }

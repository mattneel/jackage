'use strict';
// Real TypeScript semantic checking, with no ambient module-resolution host.
// argv and the JSON job are supplied only by the Zig frontend, never recipe code.
const fs = require('node:fs');
const path = require('node:path');
const compiler = path.resolve(process.argv[2]);
const lib = path.dirname(compiler);
const ts = require(compiler);
const job = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const files = new Map(job.modules.map(m => ['/locked/' + m.name, m.source]));
files.set('/sdk/jackage.d.ts', job.sdk);
const valid = name => name.length > 0 && !name.startsWith('.') && !name.startsWith('/') &&
  !/[\\:\u0000?#]/.test(name) && name.split('/').every(p => p && p !== '.' && p !== '..');
function resolve(specifier, base) {
  if (specifier === 'jackage') return '/sdk/jackage.d.ts';
  if (!specifier || specifier.startsWith('/') || /[\\:\u0000?#]/.test(specifier)) return undefined;
  const name = specifier.startsWith('./') ? base.slice('/locked/'.length, base.lastIndexOf('/') + 1) + specifier.slice(2) : specifier;
  return valid(name) && files.has('/locked/' + name) ? '/locked/' + name : undefined;
}
function read(name) {
  if (files.has(name)) return files.get(name);
  // The only filesystem reads after the job are pinned TypeScript lib files.
  if (/^\/typescript\/lib\.[a-z0-9.]+\.d\.ts$/.test(name)) {
    try { return fs.readFileSync(path.join(lib, path.posix.basename(name)), 'utf8'); }
    catch { return undefined; }
  }
  return undefined;
}
const options = {
  strict: true, noEmit: true, target: ts.ScriptTarget.ES2020,
  module: ts.ModuleKind.ESNext, moduleResolution: ts.ModuleResolutionKind.Bundler,
  allowImportingTsExtensions: true, skipLibCheck: false, types: [],
};
const host = {
  getSourceFile(name, languageVersion) {
    const source = read(name);
    return source === undefined ? undefined : ts.createSourceFile(name, source, languageVersion, true, ts.ScriptKind.TS);
  },
  getDefaultLibFileName: () => '/typescript/lib.es2020.full.d.ts',
  writeFile() { throw new Error('emission is forbidden'); },
  getCurrentDirectory: () => '/locked',
  getDirectories: () => [],
  fileExists: name => read(name) !== undefined,
  readFile: read,
  getCanonicalFileName: name => name,
  useCaseSensitiveFileNames: () => true,
  getNewLine: () => '\n',
  resolveModuleNames: (names, base) => names.map(specifier => {
    const resolvedFileName = resolve(specifier, base);
    return resolvedFileName ? {resolvedFileName, extension: resolvedFileName.endsWith('.d.ts') ? ts.Extension.Dts : ts.Extension.Ts, isExternalLibraryImport: false} : undefined;
  }),
};
const program = ts.createProgram({rootNames: [...files.keys()], options, host});
const diagnostics = ts.getPreEmitDiagnostics(program);
// Do not echo source contents, paths, or diagnostics that could contain secrets.
if (diagnostics.length) process.stderr.write('typescript diagnostic TS' + diagnostics[0].code + '; count=' + diagnostics.length + '\n');
process.exitCode = diagnostics.length ? 1 : 0;

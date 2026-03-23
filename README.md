# leyden-test-app-generator

A shell script toolkit for generating synthetic Java applications that stress-test class loading and linking at startup — purpose-built for benchmarking [Project Leyden](https://openjdk.org/projects/leyden/)'s AOT cache support in OpenJDK.

## Why This Exists

Project Leyden targets two distinct startup phases, and this generator applies pressure to both — which is worth understanding before reading benchmark results.

**JEP 483 — AOT Class Loading & Linking** caches the loaded and linked state of classes. The clearest wins come from:

- Thousands of classes spread across many JARs, each requiring ZIP decompression and manifest reads at startup
- One JAR per package, so the JVM must open and search each one in turn
- Deep 3-level abstract inheritance chains (`AbstractBase → AbstractLayer1Base → Layer1ClassN`)
- Two interfaces with multiple default methods on every class, driving interface vtable resolution at link time

**JEP 514 — AOT Method Compilation** caches compiled native code, which is where `<clinit>` cost can be reduced:

- Static initializers (`HashMap` + `ArrayList` population) on every class — these run at *initialization* time, not load/link time, so JEP 483 does not help here
- Explicit `Class.forName()` loops in `main()` that force sequential `<clinit>` execution across JAR boundaries

The `init_size` parameter controls whether static initializers are generated at all (`0` = none), letting you isolate each phase. The measured speedup in `run.sh` reflects whichever mechanisms are active. See [Relationship to Project Leyden](#relationship-to-project-leyden) for the two-variant approach.

The result is a configurable, reproducible benchmark you can tune from a few hundred classes up to tens of thousands.

---

## Scripts

### `generate_classes.sh`

Generates the Java source, compiles it, packages it into JARs, and emits a ready-to-run benchmark script.

**Usage**

```bash
./generate_classes.sh [output_dir] [total_l1] [l2_per_l1] [l1_per_pkg] [init_size]
```

**Arguments**

| Position | Name | Default | Description |
|---|---|---|---|
| `$1` | `output_dir` | `generated_java` | Root directory for all generated output |
| `$2` | `total_l1` | `100` | Total number of Layer1 (mid-tier) classes |
| `$3` | `l2_per_l1` | `50` | Layer2 leaf classes per Layer1 class |
| `$4` | `l1_per_pkg` | `10` | Layer1 classes per package / JAR |
| `$5` | `init_size` | `50` | Entries in each static initializer (`0` = no `<clinit>`, pure load/link pressure) |

`PKG_COUNT` is derived automatically as `ceil(total_l1 / l1_per_pkg)`, so partial packages get their own JAR.

**Default scale**

With defaults, the generator produces:
- 10 packages × 10 Layer1 classes each = 100 Layer1 classes
- 100 × 50 = 5,000 Layer2 leaf classes
- Plus 2 interfaces and 2 abstract base classes
- **Total: ~5,102 classes across 11 JARs** (`base.jar` + 10 `pkgN.jar` + `root.jar`)

**Output layout**

```
<output_dir>/
├── src/                  # Generated Java source tree
├── out/                  # Compiled .class files
├── jars/
│   ├── base.jar          # Interfaces + abstract base classes
│   ├── pkg0.jar          # Layer1 + Layer2 classes for package 0
│   ├── pkg1.jar          # ...
│   └── root.jar          # RootClass entry point
└── run.sh                # Auto-generated benchmark runner (see below)
```

**Requirements**

- `javac` and `jar` on `PATH` (JDK 25+ recommended)
- Bash

**Examples**

```bash
# Larger scale, default init pressure
./generate_classes.sh big_app 500 100 20
# → 25 packages, 500 L1 classes, 50,000 L2 classes, ~50,504 total

# Pure load/link pressure — no static initializers (JEP 483 story)
./generate_classes.sh demo_483 200 200 10 0

# Full pressure — load/link + initialization overhead (JEP 483 + JEP 514)
./generate_classes.sh demo_full 200 200 10
```

---

### `run.sh` *(generated)*

`generate_classes.sh` emits a `run.sh` inside `<output_dir>` tuned to the scale you generated. It runs three back-to-back trials so you can measure the AOT speedup directly.

**Usage**

```bash
<output_dir>/run.sh [GC]
```

**Arguments**

| Position | Name | Default | Description |
|---|---|---|---|
| `$1` | `GC` | *(JVM default)* | Optional GC selector: `G1`, `Parallel`, `Serial`, `Shenandoah`, or `ZGC` |


**What it runs**

```
=== Plain run ===
java ... -cp <classpath> com.example.generated.root.RootClass

=== Training run (creates app.aot) ===
java ... -XX:AOTCacheOutput=<output_dir>/app.aot -cp <classpath> RootClass

=== AOT run ===
java ... -XX:AOTCache=<output_dir>/app.aot -cp <classpath> RootClass
```

Each run prints wall-clock startup time, total class count, package count, and the active GC. Compare plain vs. AOT to see Leyden's impact at your chosen scale.

**Sample Output**

Generated with `./generate_classes.sh generated_java 200 200 10` and run with ZGC (`./generated_java/run.sh ZGC`):

```
=== Plain run ===
GC:          ZGC
Packages:    20
Classes:     40205
Wall time:   7330 ms

=== Training run ===
GC:          ZGC
Packages:    20
Classes:     40205
Wall time:   8270 ms
Temporary AOTConfiguration recorded: app.aot.config
Launching child process /home/ibrown/.sdkman/candidates/java/25.0.2-zulu/bin/java to assemble AOT cache app.aot using configuration app.aot.config
Reading AOTConfiguration app.aot.config and writing AOTCache app.aot
AOTCache creation is complete: app.aot 200642560 bytes
Removed temporary AOT configuration file app.aot.config

=== AOT run ===
GC:          ZGC
Packages:    20
Classes:     40205
Wall time:   3544 ms
```

The training run is expected to be slower than plain — it does a full run *and* drives the JVM's AOT recording and assembly pipeline. The cache itself (`app.aot`) came out at ~191 MB for 40K classes. The AOT run lands at **3,544 ms**, a **52% reduction** from the 7,330 ms cold baseline.

**Memory flags** are auto-derived from class counts and `init_size` at generation time:
- Heap (`-Xmx`): `init_size/50 × 13 KB` per Layer2 class × 1.5 + 512 MB buffer, rounded up to nearest GB (minimum 2 GB); floors at minimum when `init_size=0`
- Metaspace (`-XX:MaxMetaspaceSize`): ~4 KB per total class + 256 MB buffer, rounded up to nearest GB (minimum 1 GB)

---

### `inspect_generated.sh`

Introspects an existing `generate_classes.sh` output directory and recovers the original generation parameters by inspecting the JAR contents. Useful when you have a benchmark directory but have lost track of how it was generated.

**Usage**

```bash
./inspect_generated.sh <output_dir>
```

**Arguments**

| Position | Name | Required | Description |
|---|---|---|---|
| `$1` | `output_dir` | Yes | Path to a `generate_classes.sh` output directory |

**Output**

```
=== Recovered parameters for: big_app ===

   ./generate_classes.sh big_app 500 100 20

=== Derived values ===
   pkg_count  = 25
   total_l1   = 500
   l2_per_l1  = 100
   l1_per_pkg = 20
   total_l2   = 50000
   total_class = 50504
```

The recovered `./generate_classes.sh ...` line is copy-pasteable to recreate the same workload.

---

## Quick Start

```bash
# Generate the default benchmark (~5,100 classes, with static init)
./generate_classes.sh

# Run all three trials (plain / training / AOT)
./generated_java/run.sh

# Run with G1GC
./generated_java/run.sh G1

# Later: recover what parameters were used
./inspect_generated.sh generated_java
```

**Two-variant setup** for a controlled Leyden comparison:

```bash
# Variant 1: pure load/link pressure — isolates JEP 483
./generate_classes.sh demo_483 200 200 10 0
./demo_483/run.sh ZGC

# Variant 2: load/link + initialization — shows JEP 514 ceiling
./generate_classes.sh demo_full 200 200 10
./demo_full/run.sh ZGC
```

## Class Hierarchy

```
IComputable          ITransformable
    └──────────────────┘
           │
     AbstractBase           (static init: 4×init_size entries — omitted when init_size=0)
           │
   AbstractLayer1Base       (static init: 4×init_size entries — omitted when init_size=0)
           │
    Layer1Class_N           (static init: 2×init_size entries; holds L2_PER_L1 children)
           │
    Layer2Class_N_M         (static init:   init_size entries; leaf node)
```

`RootClass` holds a field instance of every Layer1 class, runs `Class.forName()` on one leaf per L1 class at startup, then calls `computeAll()` to traverse the entire tree.



## Relationship to Project Leyden

The `-XX:AOTCacheOutput` / `-XX:AOTCache` flags used in the generated `run.sh` invoke JEP 483 (AOT Class Loading & Linking, JDK 24+), which caches loaded and linked class state. The loading/linking pressure in this benchmark — many JARs, deep inheritance chains, interface resolution — is directly attributable to JEP 483.

The static initializers and `Class.forName()` chains are *initialization* cost (`<clinit>`), which JEP 483 does not cache. Any speedup there comes from JEP 514 (AOT Method Compilation) compiling `<clinit>` methods ahead of time.

Use `init_size` to isolate each mechanism:

| `init_size` | What you're measuring | JEP |
|---|---|---|
| `0` | Pure class loading & linking | JEP 483 |
| `> 0` (default: 50) | Loading/linking + `<clinit>` execution | JEP 483 + JEP 514 |

Scaling up `total_l1` and `l2_per_l1` models larger dependency graphs. The delta between the two variants shows what `<clinit>` overhead costs and how much JEP 514 recovers.

## License

MIT

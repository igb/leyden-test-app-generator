# leyden-test-app-generator

A shell script toolkit for generating synthetic Java applications that stress-test class loading and linking at startup — purpose-built for benchmarking [Project Leyden](https://openjdk.org/projects/leyden/)'s AOT cache support in OpenJDK.

## Why This Exists

Project Leyden's AOT caching (JEP 483/514) delivers the most measurable wins on workloads dominated by class loading. This generator lets you dial up the exact pressures that expose those gains:

- Thousands of classes spread across many JARs, each requiring ZIP decompression and manifest reads at startup
- Deep 3-level abstract inheritance chains (`AbstractBase → AbstractLayer1Base → Layer1ClassN`)
- Two interfaces with multiple default methods on every class
- Static initializers (`HashMap` + `ArrayList` population) on every class
- Explicit `Class.forName()` loops in `main()` that force sequential `<clinit>` chains
- One JAR per package, so the JVM must open and search each one in turn

The result is a configurable, reproducible benchmark you can tune from a few hundred classes up to tens of thousands.

---

## Scripts

### `generate_classes.sh`

Generates the Java source, compiles it, packages it into JARs, and emits a ready-to-run benchmark script.

**Usage**

```bash
./generate_classes.sh [output_dir] [total_l1] [l2_per_l1] [l1_per_pkg]
```

**Arguments**

| Position | Name | Default | Description |
|---|---|---|---|
| `$1` | `output_dir` | `generated_java` | Root directory for all generated output |
| `$2` | `total_l1` | `100` | Total number of Layer1 (mid-tier) classes |
| `$3` | `l2_per_l1` | `50` | Layer2 leaf classes per Layer1 class |
| `$4` | `l1_per_pkg` | `10` | Layer1 classes per package / JAR |

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

- `javac` and `jar` on `PATH` (JDK 21+ recommended; JDK 24/25 for AOT cache flags)
- Bash

**Example: larger scale run**

```bash
./generate_classes.sh big_app 500 100 20
# → 25 packages, 500 L1 classes, 50,000 L2 classes, ~50,504 total
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

Note: `ZGC` is handled specially — it maps to `-XX:+UseZGC` rather than `-XX:+UseZGCGC`.

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

**Memory flags** are auto-derived from class counts at generation time:
- Heap (`-Xmx`): ~13 KB per Layer2 class × 1.5 + 512 MB buffer, rounded up to nearest GB (minimum 2 GB)
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
# Generate the default benchmark (~5,100 classes)
./generate_classes.sh

# Run all three trials (plain / training / AOT)
./generated_java/run.sh

# Run with G1GC
./generated_java/run.sh G1

# Later: recover what parameters were used
./inspect_generated.sh generated_java
```

## Class Hierarchy

```
IComputable          ITransformable
    └──────────────────┘
           │
     AbstractBase           (static init: 200-entry HashMap + ArrayList)
           │
   AbstractLayer1Base       (static init: 200-entry HashMap + ArrayList)
           │
    Layer1Class_N           (static init: 100-entry map; holds L2_PER_L1 children)
           │
    Layer2Class_N_M         (static init:  50-entry map; leaf node)
```

`RootClass` holds a field instance of every Layer1 class, runs `Class.forName()` on one leaf per L1 class at startup, then calls `computeAll()` to traverse the entire tree.

```markdown
## Sample Output

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
```
## Relationship to Project Leyden

The `-XX:AOTCacheOutput` / `-XX:AOTCache` flags used in the generated `run.sh` correspond to JEP 483 (JDK 24+). This workload is designed to be representative of microservice-style applications where startup time is dominated by class loading and linking rather than computation. Scaling up `total_l1` and `l2_per_l1` lets you model larger dependency graphs and observe how Leyden's AOT cache warm-up benefits scale with classpath size.

## License

MIT

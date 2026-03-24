#!/usr/bin/env bash
# Generates a Java app where class loading + linking dominate startup.
#
# Pressure from:
#   - 5,000+ classes spread across derived packages → one JAR per package
#   - JVM must open/search each JAR (ZIP decompression, manifest reads)
#   - 3-level abstract inheritance chain per Layer1 class
#   - 2 interfaces with default methods on every class
#   - Explicit Class.forName() loop forcing sequential class loading in main()
#
# No static initializers — pure class loading & linking pressure (JEP 483).
#
# Usage: ./generate_classes.sh [output_dir] [total_l1] [l2_per_l1] [l1_per_pkg]
#   total_l1    = total number of Layer1 classes                  (default: 100)
#   l2_per_l1   = Layer2 classes per Layer1                       (default: 50)
#   l1_per_pkg  = Layer1 classes per package/JAR                  (default: 10)
#
# PKG_COUNT is derived: ceil(total_l1 / l1_per_pkg)
# Default: ceil(100/10)=10 pkgs × (10 L1 + 500 L2) = 5,105 classes + base + root

set -euo pipefail

OUTPUT_DIR="${1:-generated_java}"
TOTAL_L1="${2:-100}"
L2_PER_L1="${3:-50}"
L1_PER_PKG="${4:-10}"

# Derive package count — ceiling division so remainders get their own package
PKG_COUNT=$(( (TOTAL_L1 + L1_PER_PKG - 1) / L1_PER_PKG ))

BASE_PKG="com.example.generated"
BASE_PKG_PATH="com/example/generated"

SRC="$OUTPUT_DIR/src"
OUT="$OUTPUT_DIR/out"
JARS="$OUTPUT_DIR/jars"

TOTAL_L2=$(( TOTAL_L1 * L2_PER_L1 ))
TOTAL=$(( 1 + TOTAL_L1 + TOTAL_L2 + 4 ))   # +4: 2 interfaces, 2 abstracts

mkdir -p "$OUT" "$JARS"

echo "=== Java class-loading benchmark generator ==="
echo "Packages (JARs):      $PKG_COUNT"
echo "Layer1 per package:   $L1_PER_PKG"
echo "Layer2 per Layer1:    $L2_PER_L1"
echo "Total classes:        $TOTAL"
echo "Static initializers:  none — pure load/link pressure (JEP 483)"
echo ""

# ---------------------------------------------------------------------------
# Helper: make a source directory for a package
# ---------------------------------------------------------------------------
pkg_src() { echo "$SRC/${BASE_PKG_PATH}/$1"; }

mkdir -p "$(pkg_src base)"

# ---------------------------------------------------------------------------
# base package — interfaces + abstract classes
# Compiled first; all other packages depend on it.
# ---------------------------------------------------------------------------
BASE_FULL="${BASE_PKG}.base"

cat > "$(pkg_src base)/IComputable.java" << JAVA
package $BASE_FULL;

public interface IComputable {
    int compute(int x);
    default int computeTwice(int x)    { return compute(x) * 2; }
    default int computeSquared(int x)  { int v = compute(x); return v * v; }
    default String computeLabel(int x) { return getClass().getSimpleName() + "=" + compute(x); }
}
JAVA

cat > "$(pkg_src base)/ITransformable.java" << JAVA
package $BASE_FULL;

public interface ITransformable {
    String transform(String s);
    default String transformAndRepeat(String s) { return transform(s) + "|" + transform(s); }
    default String transformUpper(String s)      { return transform(s).toUpperCase(); }
    default String transformWrapped(String s)    { return "[" + transform(s) + "]"; }
}
JAVA

cat > "$(pkg_src base)/AbstractBase.java" << JAVA
package $BASE_FULL;

public abstract class AbstractBase implements IComputable, ITransformable {

    protected final String name;
    private int callCount = 0;

    protected AbstractBase(String name) { this.name = name; }

    public String getName()   { return name; }
    public int getCallCount() { return callCount; }
    protected void tick()     { callCount++; }

    public static int registrySize() { return 0; }
}
JAVA

cat > "$(pkg_src base)/AbstractLayer1Base.java" << JAVA
package $BASE_FULL;

public abstract class AbstractLayer1Base extends AbstractBase {

    protected AbstractLayer1Base(String name) { super(name); }

    public abstract String collectNames();
    public abstract int    computeAll(int x);
    public abstract String transformAll(String s);

    public static int indexSize() { return 0; }
}
JAVA

echo "Compiling base package..."
find "$(pkg_src base)" -name "*.java" > /tmp/gen_sources.txt
javac -d "$OUT" @/tmp/gen_sources.txt
jar cf "$JARS/base.jar" -C "$OUT" "${BASE_PKG_PATH}/base"
echo "  -> $JARS/base.jar"

# ---------------------------------------------------------------------------
# pkg0..pkgN-1 — each gets L1_PER_PKG Layer1 classes + their Layer2 classes
# ---------------------------------------------------------------------------
for p in $(seq 0 $(( PKG_COUNT - 1 ))); do
    PKG_NAME="pkg${p}"
    PKG_FULL="${BASE_PKG}.${PKG_NAME}"
    PKG_DIR="$(pkg_src "$PKG_NAME")"
    mkdir -p "$PKG_DIR"

    # Global Layer1 index offset for this package; last package may have fewer
    L1_OFFSET=$(( p * L1_PER_PKG ))
    L1_END=$(( L1_OFFSET + L1_PER_PKG < TOTAL_L1 ? L1_OFFSET + L1_PER_PKG : TOTAL_L1 ))
    L1_THIS=$(( L1_END - L1_OFFSET ))

    echo "Generating package $PKG_NAME (L1 $L1_OFFSET..$(( L1_END - 1 )), $L1_THIS classes)..."

    # -- Layer2 leaf classes --------------------------------------------------
    for li in $(seq 0 $(( L1_THIS - 1 ))); do
        GLOBAL_I=$(( L1_OFFSET + li ))
        for j in $(seq 0 $(( L2_PER_L1 - 1 ))); do
            CLASS="Layer2Class_${GLOBAL_I}_${j}"
            cat > "$PKG_DIR/${CLASS}.java" << JAVA
package $PKG_FULL;

import ${BASE_FULL}.AbstractBase;

public class $CLASS extends AbstractBase {

    public $CLASS() { super("$CLASS"); }

    @Override
    public int compute(int x) {
        tick();
        return x * $j + $GLOBAL_I;
    }

    @Override
    public String transform(String s) {
        tick();
        return "[$CLASS:" + s + "]";
    }

    public boolean isEven(int n)   { return (n % 2) == 0; }
    public String  label()         { return computeLabel($j); }
    public String  upper(String s) { return transformUpper(s); }
}
JAVA
        done
    done

    # -- Layer1 middle classes ------------------------------------------------
    for li in $(seq 0 $(( L1_THIS - 1 ))); do
        GLOBAL_I=$(( L1_OFFSET + li ))
        CLASS="Layer1Class_${GLOBAL_I}"
        {
            echo "package $PKG_FULL;"
            echo ""
            echo "import ${BASE_FULL}.AbstractLayer1Base;"
            for j in $(seq 0 $(( L2_PER_L1 - 1 ))); do
                echo "import ${PKG_FULL}.Layer2Class_${GLOBAL_I}_${j};"
            done

            cat << JAVA

public class $CLASS extends AbstractLayer1Base {

JAVA

            for j in $(seq 0 $(( L2_PER_L1 - 1 ))); do
                echo "    private final Layer2Class_${GLOBAL_I}_${j} child${j} = new Layer2Class_${GLOBAL_I}_${j}();"
            done

            cat << JAVA

    public $CLASS() { super("$CLASS"); }

    @Override public int    compute(int x)       { tick(); return $GLOBAL_I; }
    @Override public String transform(String s)  { tick(); return "[$CLASS:" + s + "]"; }

    @Override
    public String collectNames() {
        StringBuilder sb = new StringBuilder(name + ":");
JAVA
            for j in $(seq 0 $(( L2_PER_L1 - 1 ))); do
                echo "        sb.append(child${j}.getName()).append(\",\");"
            done
            cat << JAVA
        return sb.toString();
    }

    @Override
    public int computeAll(int x) {
        int total = $GLOBAL_I;
JAVA
            for j in $(seq 0 $(( L2_PER_L1 - 1 ))); do
                echo "        total += child${j}.compute(x);"
            done
            cat << JAVA
        return total;
    }

    @Override
    public String transformAll(String s) {
        StringBuilder sb = new StringBuilder();
JAVA
            for j in $(seq 0 $(( L2_PER_L1 - 1 ))); do
                echo "        sb.append(child${j}.transform(s));"
            done
            cat << JAVA
        return sb.toString();
    }
}
JAVA
        } > "$PKG_DIR/${CLASS}.java"
    done

    # -- Compile and jar this package -----------------------------------------
    find "$PKG_DIR" -name "*.java" > /tmp/gen_sources.txt
    javac -cp "$JARS/base.jar" -d "$OUT" @/tmp/gen_sources.txt
    jar cf "$JARS/${PKG_NAME}.jar" -C "$OUT" "${BASE_PKG_PATH}/${PKG_NAME}"
    echo "  -> $JARS/${PKG_NAME}.jar  ($(( L1_THIS + L1_THIS * L2_PER_L1 )) classes)"
done

# ---------------------------------------------------------------------------
# root package — RootClass only
# ---------------------------------------------------------------------------
ROOT_DIR="$(pkg_src root)"
mkdir -p "$ROOT_DIR"

echo "Generating RootClass..."

# Build the classpath string for compilation: base + all pkg jars
ALL_JARS="$JARS/base.jar"
for p in $(seq 0 $(( PKG_COUNT - 1 ))); do
    ALL_JARS="$ALL_JARS:$JARS/pkg${p}.jar"
done

{
    echo "package ${BASE_PKG}.root;"
    echo ""
    # Iterate by global index — derive package inline, handles remainder correctly
    for gi in $(seq 0 $(( TOTAL_L1 - 1 ))); do
        p=$(( gi / L1_PER_PKG ))
        echo "import ${BASE_PKG}.pkg${p}.Layer1Class_${gi};"
    done
    cat << JAVA

/**
 * Entry point. Directly loads $TOTAL_L1 Layer1 classes (across $PKG_COUNT packages/JARs),
 * which transitively load $TOTAL_L2 Layer2 leaf classes. Total: $TOTAL class files.
 *
 * Run with maximum class-loading pressure:
 *   java -cp <classpath> ${BASE_PKG}.root.RootClass
 *
 * Count loaded classes:
 *   java -verbose:class -cp <classpath> ${BASE_PKG}.root.RootClass 2>&1 | grep -c '\[Loaded'
 */
import java.lang.management.ManagementFactory;
import java.lang.management.GarbageCollectorMXBean;

public class RootClass {

JAVA
    for gi in $(seq 0 $(( TOTAL_L1 - 1 ))); do
        echo "    private final Layer1Class_${gi} l1_${gi} = new Layer1Class_${gi}();"
    done
    cat << JAVA

    public static void main(String[] args) throws Exception {
        long t0 = System.nanoTime();

        // Force sequential class loading on one leaf class per L1 class via reflection.
        // Each call crosses a JAR boundary, triggering ZIP entry lookup.
        for (int gi = 0; gi < $TOTAL_L1; gi++) {
            int p = gi / $L1_PER_PKG;
            Class.forName("${BASE_PKG}.pkg" + p + ".Layer2Class_" + gi + "_0");
        }

        RootClass root = new RootClass();
        root.computeAll(7);

        String raw = ManagementFactory.getGarbageCollectorMXBeans().get(0).getName().split(" ")[0];
        String gc  = raw.equals("PS") ? "Parallel" : raw;
        System.out.println("GC:          " + gc);
        System.out.println("Packages:    $PKG_COUNT");
        System.out.println("Classes:     $TOTAL");
        System.out.println("Wall time:   " + (System.nanoTime() - t0) / 1_000_000 + " ms");
    }

    public int computeAll(int x) {
        int total = 0;
JAVA
    for gi in $(seq 0 $(( TOTAL_L1 - 1 ))); do
        echo "        total += l1_${gi}.computeAll(x);"
    done
    cat << JAVA
        return total;
    }

    public String collectAllNames() {
        StringBuilder sb = new StringBuilder();
JAVA
    for gi in $(seq 0 $(( TOTAL_L1 - 1 ))); do
        echo "        sb.append(l1_${gi}.collectNames()).append(\"\\n\");"
    done
    cat << JAVA
        return sb.toString();
    }
}
JAVA
} > "$ROOT_DIR/RootClass.java"

javac -cp "$ALL_JARS" -d "$OUT" "$ROOT_DIR/RootClass.java"
jar cf "$JARS/root.jar" -C "$OUT" "${BASE_PKG_PATH}/root"
echo "  -> $JARS/root.jar"

# ---------------------------------------------------------------------------
# Emit a run script
# ---------------------------------------------------------------------------
CLASSPATH="$JARS/root.jar:$ALL_JARS"

# Derive metaspace from class count; heap floors at 2g (no static init data)
XMX=2g
_META_MB=$(( TOTAL * 4 / 1024 + 256 ))
_META_GB=$(( (_META_MB + 1023) / 1024 ))
MAX_META=$(( _META_GB < 1 ? 1 : _META_GB ))g

cat > "$OUTPUT_DIR/run.sh" << SCRIPT
#!/usr/bin/env bash
# Auto-generated — run the benchmark
# Classes: $TOTAL  (L1=$TOTAL_L1  L2=$TOTAL_L2  pkgs=$PKG_COUNT)
#
# Usage: ./run.sh [GC]
#   GC  optional GC flag suffix: G1, Parallel, Serial, Shenandoah  (default: JVM default)
#       ZGC is special: pass ZGC (not ZGCGC)
#   e.g. ./run.sh ZGC  or  ./run.sh G1

CLASSPATH="$CLASSPATH"
MAIN="${BASE_PKG}.root.RootClass"
AOT_CACHE="\$(dirname "\$0")/app.aot"

# Memory: heap ~${XMX}, metaspace ~${MAX_META}
MEM="-Xmx${XMX} -XX:MaxMetaspaceSize=${MAX_META}"

GC_FLAG=""
if [[ -n "\${1:-}" ]]; then
    gc="\$1"
    # ZGC flag is -XX:+UseZGC (not UseZGCGC); all others follow UseXxxGC pattern
    if [[ "\$gc" == "ZGC" || "\$gc" == "zgc" ]]; then
        GC_FLAG="-XX:+UseZGC"
    else
        GC_FLAG="-XX:+Use\${gc}GC"
    fi
fi

echo "=== Plain run ==="
java \$MEM \$GC_FLAG -cp "\$CLASSPATH" "\$MAIN"

echo ""
echo "=== Training run (creates \$AOT_CACHE) ==="
java \$MEM \$GC_FLAG -XX:AOTCacheOutput="\$AOT_CACHE" -cp "\$CLASSPATH" "\$MAIN"

echo ""
echo "=== AOT run ==="
java \$MEM \$GC_FLAG -XX:AOTCache="\$AOT_CACHE" -cp "\$CLASSPATH" "\$MAIN"
SCRIPT
chmod +x "$OUTPUT_DIR/run.sh"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Done ==="
ls -lh "$JARS"/*.jar
echo ""
echo "Run: $OUTPUT_DIR/run.sh"
echo ""
echo "Or manually:"
echo "  java -cp $CLASSPATH \\"
echo "       ${BASE_PKG}.root.RootClass"

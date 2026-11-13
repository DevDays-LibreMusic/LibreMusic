"""Run pure JVM numeric/model-store tests using cached pinned dependencies.
Real inference is optional via MORNYE_WAVLM_MODEL/MORNYE_DEMUCS_MODEL; no downloads.
"""
from pathlib import Path
import subprocess, os
base=Path.home()/'.gradle/caches/modules-2/files-2.1'
def jar(group,artifact,version):return str(next((base/group/artifact/version).rglob('*.jar')))
std=jar('org.jetbrains.kotlin','kotlin-stdlib','2.4.21')
compiler=[jar('org.jetbrains.kotlin','kotlin-compiler-embeddable','2.4.21'),std,jar('org.jetbrains.kotlin','kotlin-script-runtime','2.4.21'),jar('org.jetbrains.kotlin','kotlin-reflect','2.4.10'),jar('org.jetbrains.kotlinx','kotlinx-coroutines-core-jvm','1.11.0'),jar('org.jetbrains','annotations','23.0.0')]
cp=[std,jar('junit','junit','4.13.2'),jar('org.hamcrest','hamcrest-core','1.3'),jar('org.json','json','20260814'),str(Path.home()/'.cache/libremusic-onnx/onnxruntime-1.31.1-desktop.jar'),compiler[-1]]
java=str(Path.home()/'.local/share/mise/installs/java/temurin-25.0.5+8.0.LTS/Contents/Home/bin/java')
sources=['android/app/src/main/kotlin/com/zarz/mornye/AudioVersionModelStore.kt','android/app/src/main/kotlin/com/zarz/mornye/AudioVersionWavlmRuntime.kt','android/app/src/main/kotlin/com/zarz/mornye/AudioVersionDemucsRuntime.kt']+[str(p) for p in Path('android/app/src/test/kotlin/com/zarz/mornye').glob('AudioVersion*Test.kt')]
import tempfile
output_directory=tempfile.TemporaryDirectory(prefix='libremusic-model-jvm-')
out=str(Path(output_directory.name)/'tests.jar')
subprocess.run([java,'-cp',':'.join(compiler),'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler','-no-stdlib','-no-reflect','-jvm-target','17','-classpath',':'.join(cp),'-d',out,*sources],check=True)
# Opt in to actual inference using MORNYE_WAVLM_MODEL and MORNYE_DEMUCS_MODEL.
# Missing external models skip only those expensive inference tests.
subprocess.run([java,'-Xmx3g','-cp',':'.join([out,'android/app/src/test/resources',*cp]),'org.junit.runner.JUnitCore','com.zarz.mornye.AudioVersionModelStoreTest','com.zarz.mornye.AudioVersionClipMathTest','com.zarz.mornye.AudioVersionWavlmRuntimeTest','com.zarz.mornye.AudioVersionDemucsRuntimeTest'],check=True)

# Motores de transcripción local

El servicio admite faster-whisper y whisper.cpp. El segundo se registra únicamente
si se configura `WHISPER_CPP_EXE`; requiere `WHISPER_CPP_MODEL` y `FFMPEG_EXE`.
Estas rutas privadas no se incluyen en el repositorio. No se descargan ejecutables
ni modelos automáticamente. La licencia de cada dependencia sigue siendo aplicable.

`TRANSCRIPTION_DEFAULT_ENGINE=whisper-cpp-base` selecciona el perfil ligero.
`WHISPER_CPP_DEVICE` admite `auto`, `cpu` y `gpu`. En modo auto se intenta primero
la ejecución normal del binario, con GPU habilitada. Si devuelve un código de error
se reintenta con `-ng` (CPU). Los timeouts no se reintentan automáticamente. El motor
puede elegir CPU internamente; no se afirma uso efectivo de GPU por el mero hecho
de solicitarlo. `execution` informa modelo, modo solicitado y fallback explícito.
Actas avisa si se ha utilizado ese fallback. La detección depende del backend del
ejecutable, no admite sumar VRAM ni repartir modelos mediante NVLink.

Validación local 24/10/2026: whisper.cpp Vulkan con base.bin produjo las dos frases
del audio sintético en modo auto y CPU. La ayuda del ejecutable enumeró una RTX 3090;
nvidia-smi enumeró dos RTX 3090 de 24576 MiB. El perfil faster-whisper conserva su
configuración previa de GPU. No se ha realizado un benchmark comparativo de calidad
ni se garantiza el mismo rendimiento en otros equipos.

La instalación local se actualizó con copia previa. Prueba real REST: consulta de
dos motores, carga con whisper-cpp-base y reintento con faster-whisper sobre el mismo
audio_id, ambos con dos segmentos. El archivo permanente está en
`IA-local/services/private-audio`; incluirlo en los backups privados.

La ventana Tk se construyó correctamente con los permisos del usuario. La prueba
anterior de Tcl fallaba por acceso del entorno de validación. No equivale a una
revisión visual completa de todos los diálogos. Reiniciar Actas mediante el lanzador
de servicios para cargar el selector nuevo; «Consultar motores» selecciona el valor
predeterminado del servidor. La selección no modifica transcripciones anteriores.

Pendientes: perfiles editables de modelo/dispositivo en la interfaz, recuperación
de originales de sesiones anteriores, guardar metadatos de ejecución por intento,
configuración multigpu y traducción intercambiable. El formato académico experimental
se documenta por separado en `academic-export.md`; APA7 completo sigue pendiente.

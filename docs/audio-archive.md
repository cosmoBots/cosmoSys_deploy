# Archivo de audio: primera entrega

El servicio de transcripción guarda los bytes originales recibidos antes de ejecutar
Whisper. Usa `TRANSCRIPTION_DATA_DIR` o, por defecto, `services/private-audio`.
La extensión interna `.audio` no convierte el contenido: un WAV conserva sus bytes.
El directorio está excluido de Git; debe protegerse con permisos del usuario e
incluirse completo en las copias de seguridad (con el servicio detenido).

SQLite registra identidad SHA-256, tamaño, fecha e intentos. Cada intento conserva
motor, estado y resultado. Los originales idénticos comparten un archivo. La respuesta
REST incluye `audio_id`, también cuando falla el motor después de archivar el audio.
Una carga incompleta no se considera un original archivado. Un error de disco impide
iniciar la transcripción. No hay borrado automático ni cuota total implementada.

`AudioArchive.transcribe` admite un registro de proveedores intercambiables y permite
reintentar por identidad después de reiniciar. Los intentos fallidos no borran el
original ni los resultados anteriores. Antes de cada intento verifica integridad.
Un cierre abrupto puede dejar un intento en estado `running`; aún no hay reconciliación.

Esta entrega conecta el archivo al servidor, pero solo registra el adaptador real
faster-whisper. Quedan pendientes el selector y reintento desde la interfaz/REST,
un segundo motor real, metadatos de modelo/dispositivo/duración, vínculo con proyectos
y actas, y detección GPU con alternativa CPU. Las pruebas de intercambio de proveedores
usan dobles de prueba, no validan dos motores de IA reales. No modifica las correcciones
editoriales existentes. No sustituye automáticamente un servicio ya ejecutándose.

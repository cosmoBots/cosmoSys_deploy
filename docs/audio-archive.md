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
faster-whisper. El cliente de actas permite consultar motores y reintentar el último
original de la sesión. Quedan pendientes la recuperación de sesiones anteriores,
un segundo motor real, metadatos de modelo/dispositivo/duración, vínculo con proyectos
y actas, y detección GPU con alternativa CPU. Las pruebas de intercambio de proveedores
usan dobles de prueba, no validan dos motores de IA reales. No modifica las correcciones
editoriales existentes. No sustituye automáticamente un servicio ya ejecutándose.

## API de reintento

Todas las operaciones requieren el mismo token Bearer del servicio de transcripción.
`GET /v1/transcription-engines` enumera proveedores registrados; no comprueba su
disponibilidad ni descarga modelos. `POST /v1/transcriptions` permite seleccionar
el proveedor con `X-Transcription-Engine` y devuelve `audio_id` y `engine`.

`POST /v1/transcriptions/retry`, con Content-Type application/json y cuerpo
`{"audio_id":"<SHA-256 del original>","engine":"faster-whisper"}`, vuelve a
transcribir el original guardado. No acepta rutas ni órdenes ejecutables. Un
proveedor desconocido se rechaza; un original ausente devuelve 404. Comparte el
límite de un trabajo activo con las cargas nuevas. Cada reintento agrega historial.
El cliente Python expone `transcription_engines`, `retry_transcription` y
`transcribe(..., include_metadata=True)`; conserva el retorno anterior por defecto.

Validación: prueba HTTP con fallo de proveedor, recuperación con otro proveedor
simulado, autenticación, identidad inválida, original inexistente e historial.
El servidor de producción sigue configurando únicamente faster-whisper.

En modo servicios, Actas ofrece «Consultar motores» y «Reintentar original».
El resultado aparece en una ventana de revisión. Para sustituir una transcripción
editable ya existente exige guardar primero una copia del texto actual; cancelar
el guardado conserva el texto anterior. Un fallo HTTP con audio_id mantiene ese
identificador para reintentar. No se publica ningún resultado automáticamente.

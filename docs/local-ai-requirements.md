# Requisitos de IA local

Registrados el 23 de octubre de 2026. Este documento recoge requisitos; no acredita su implementación.

Estado revisado el 25/10/2026: archivo persistente, reintento REST, selector de dos
motores reales y perfil ligero whisper.cpp base implementados y probados localmente.
Se probó CPU y ejecución normal con GPU habilitada; el uso efectivo y la selección
de GPU dependen del backend. No hay benchmark de calidad ni reparto NVLink.
Siguen pendientes traducción intercambiable, selector libre de modelos/dispositivos,
historial navegable, metadatos completos persistidos y backup periódico del audio.
Los criterios siguientes son el contrato completo, no una lista de todo pendiente.
Véanse `transcription-engines.md` y `PROJECT-STATUS.md`.

## Motores intercambiables y equipos modestos

- Permitir cambiar el motor y el modelo de traducción. Aplicar también esta capacidad a la transcripción de audio, que motivó la propuesta.
- Proporcionar una opción predeterminada eficiente para equipos con pocos recursos. No exigir una RTX 3090 ni una GPU dedicada. La selección concreta del motor/modelo queda pendiente de pruebas de calidad, memoria y velocidad.
- Detectar y tratar de utilizar una GPU compatible siempre que exista, comprobando soporte del motor, controladores y memoria disponible. Si no se puede utilizar, permitir continuar en CPU e informar del motivo.
- Permitir selección automática del dispositivo y configuración manual de motor, modelo y dispositivo. Mostrar solo opciones instaladas como disponibles; distinguir las que requieren instalación.
- Mantener una interfaz REST estable y adaptadores de motor separados de los clientes y de la lógica de actas/publicación.

## Conservación del original y reintentos

- Conservar el audio original en un directorio persistente de datos de la aplicación, fuera de Git, incluido en las copias de seguridad; registrar su identidad, ubicación e integridad en la base de datos.
- Conservar el original aunque falle el motor. Permitir reintentar con otro motor/modelo sin volver a grabar.
- Registrar cada resultado con motor, modelo, idioma y dispositivo utilizados; preservar versiones y correcciones del usuario.
- Permitir elegir qué transcripción se utiliza para generar el acta o alimentar el destino. Para traducción, conservar igualmente el texto fuente y las versiones traducidas.

## Criterios de aceptación pendientes

- Probar el flujo en CPU sin GPU y en una GPU compatible; verificar la selección automática y la alternativa ante error de GPU.
- Probar al menos dos adaptadores reales antes de considerar implementado el cambio de motor.
- Verificar que un fallo y un reintento conservan el original y las correcciones anteriores.
- Documentar los recursos y las limitaciones de la opción predeterminada a partir de mediciones.

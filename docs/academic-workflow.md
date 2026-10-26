# Universo → instancia TFG → Word APA7

El universo conserva fuentes y conceptos en cosmoSys. «Crear instancia TFG local»
crea un documento independiente en el gestor, enlazado al universo, con Resumen,
Introducción, Método, Resultados, Discusión y Referencias. No modifica las fuentes.
La estructura inicial es editable, no una plantilla institucional obligatoria.

Abrir «Portada y exportación APA7», completar y guardar los datos. Cada apartado
admite un uso: cuerpo, resumen, referencias, cita en bloque o excluir el apartado
y sus descendientes. «Revisar y exportar Word APA7» muestra advertencias.

## Formato y retorno

`GET /export?work=<id>&profile=apa7-student` requiere sesión. Incluye portada,
paginación, Times New Roman 12, doble espacio, márgenes de 2,54 cm, papel Carta
(A4 seleccionable), cinco niveles de títulos, niveles 4 y 5 integrados en el
párrafo, resumen sin sangría y referencias con sangría francesa. Las referencias
revisadas de las notas se deduplican y ordenan en un apartado generado. El formato
de revistas y volúmenes se reconoce conservadoramente; no cubre todos los tipos
bibliográficos.

La salida es determinista con los mismos datos y clave. El manifiesto firmado
conserva identificadores y originales. Editar títulos y texto dentro de sus
controles de contenido de Word: la importación muestra diferencias y comprueba
revisiones antes de aplicarlas. En una instancia local las correcciones se guardan
en el gestor, sin escribir en el universo.

Portada, referencias generadas y estructura se editan en el gestor. Se rechazan
cambios a elementos fijos, seguimiento de cambios pendiente, tablas, figuras y
notas al pie añadidas. Se admiten el campo PAGE normalizado y los separadores de
notas vacíos introducidos por Microsoft Word al guardar.

## API y compatibilidad

- `POST /api/create-instance`: proyecto, fuente opcional, título y token idempotente.
- `POST /api/save-publication`: metadatos con control de revisión.
- `POST /api/export-check`: advertencias y exclusiones.
- `POST /api/import-preview`: diferencias antes de aplicar la importación existente.

Se mantienen los perfiles estándar y academic-base. Las escrituras conservan
autenticación y protección CSRF. Los metadatos se guardan en las notas del trabajo.

## Límites y pruebas

No certifica conformidad completa APA7 ni cumplimiento de una guía universitaria.
No verifica fuentes o correspondencia de citas y referencias ni convierte tablas
escritas con barras en tablas APA. Las referencias mezcladas con notas editoriales
generan advertencias y conservan su orden. Revisar antes de entregar.

Pruebas: cinco niveles, determinismo, exclusión de ramas, corrección reversible,
conflictos, idempotencia y múltiples instancias por universo. Se revisó la salida
renderizada en Microsoft Word y su regrabación. Documentos personales fuera de Git.

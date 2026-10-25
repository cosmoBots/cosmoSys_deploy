# Universo, instancia documental y exportación

El universo de conocimiento permanece en cosmoSys. Una instancia documental local
del gestor académico guarda sus secciones y texto en `document_nodes` (SQLite del
gestor), con referencias a las fichas del universo en las notas. El exportador
consume la instancia; no convierte sus capítulos en entidades del universo.

`works.storage` distingue `local` de `cosmosys`. La migración mantiene los trabajos
anteriores como ramas conectadas a cosmoSys. `Store.add_document` importa un árbol
local con identidades `section:`; rechaza sobrescribir un documento existente.
El contrato de la interfaz, el guardado con revisión, creación de apartados y
exportación/importación reversible admiten ambas modalidades. La conexión de ramas
existentes conserva su comportamiento. La creación interactiva de nuevas instancias
locales aún requiere un importador; no se ofrece como asistente general.

El manifiesto Word de una instancia contiene `storage=academic-local` y
`document_id`. La importación comprueba ambos antes de aplicar cambios. Una edición
local no llama a la escritura de cosmoSys. La fuente remota puede quedar inaccesible:
en ese caso el documento sigue disponible y muestra un aviso, con catálogo de fuentes
vacío hasta la reconexión. No hay sincronización automática con Google Drive.

La copia de fuentes que ya forme parte de un anexo se conserva como instantánea
documental, no se considera una segunda entidad canónica. La revisión humana debe
decidir qué anexos se incluyen en una futura entrega; importar no certifica autoría,
validez científica ni conformidad académica del contenido.

Pruebas: reimportación sin diferencias, ediciones locales sin mutaciones remotas,
idempotencia, conflictos de revisión y rechazo de sobrescritura de una instancia.
Respaldar SQLite mediante su API de backup antes de migrar; no copiar solo el archivo
de una base abierta. Datos privados e importaciones quedan fuera del repositorio.

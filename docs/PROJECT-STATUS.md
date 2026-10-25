# Estado y especificaciones consolidadas

Auditoría del 25/10/2026. Distinguir código, instalación y validación: una función
presente en Git no necesariamente está activa. Este inventario sustituye las
descripciones de estado anteriores; sus pruebas históricas conservan su fecha.

Actualización posterior del mismo día: cerrado el desajuste de clientes. Se copió
app.py y rest_adapter.py al intercambio instalado, con backup previo, y se añadió
el lanzador documentado en `client-launcher.md`. Los tres accesos directos cargan
ahora explícitamente la configuración privada existente. Historias fue iniciado.
Autenticación REST contra cosmoSys y CGRol correcta; las dos obras narrativas y la
obra académica pasaron exportación HTTP, lectura del Word y vista previa de
reimportación sin cambios. No se aplicaron modificaciones a sus textos.
Pasaron 9 pruebas de intercambio y 4 de gestores, incluidas edición, conflicto e
idempotencia de instancia de prueba. Coinciden los hashes de los 16 archivos de
código de clientes comprobados. No equivale a revisión visual completa ni a
actualización de los plugins/VM. El inventario inferior conserva el diagnóstico
inicial para explicar la intervención; punto 1 cerrado para estos clientes.

## Contrato funcional acordado

1. cosmoSys almacena el universo: conceptos, personajes, lugares, hipótesis,
   evidencias y fuentes. Las fuentes de trabajo se distinguen del documento final.
2. Los gestores almacenan obras que usan ese universo: historia, propuesta musical,
   partida de rol o trabajo académico. «Instancia» designa aquí una obra contextual,
   no una afirmación formal de pertenencia ontológica. CGRol sigue especializado
   en rol. Una misma base puede alimentar varias obras, sin duplicar el canon.
3. Exportadores producen libro, guion, episodios o documento académico desde una
   rama ordenada. Exportar no convierte por sí solo una obra en otro medio.
4. Word/TXT reversible conserva identidades, jerarquía, títulos y correspondencia
   con fragmentos; muestra cambios antes de aplicarlos y detecta conflictos.
   La ida y vuelta determinista no debe incorporar generación aleatoria.
5. Gestores web con direcciones propias y capas REST. IA, actas y publicación
   desacopladas; originales persistentes, revisión humana y motores sustituibles.
6. Código validado se conserva en el fork del usuario. Datos privados, credenciales,
   audios y modelos quedan fuera de Git. Contribuir a upstream requiere revisión;
   Txinto no figura como autor de estas adiciones.

## Implementación y límites

| Área | Disponible | Pendiente o límite |
|---|---|---|
| Intercambio | DOCX/TXT, rama, orden, controles firmados, revisión y conflictos | No importa cualquier Word; reordenación arbitraria y copia compleja requieren validar |
| Académico | Instancia local SQLite referenciada al universo; edición y reimportación local | Asistente genérico de creación de instancias; migración deliberada de obras antiguas |
| Historias | Gestor web y notas narrativas | No es generador de guiones, temporadas ni vídeo; no se han migrado todas las obras a almacenamiento local |
| Música y otros medios | Especificación de obras que comparten universo | Gestores de producción musical, vídeo, aplicaciones y exportadores respectivos |
| APA7 | Perfil Word académico determinista experimental | Portada, paginación, niveles APA, referencias/citas, tablas/figuras, plantillas y revisión visual; véase academic-export.md |
| Semántica | Plugin y validaciones probados en entorno aislado | API semántica no activa en instalación de uso; relaciones documentadas no equivalen a restricciones ejecutables |
| Ontología | Tipos y relaciones explícitos propuestos | Versiones de universo, canon/contextos, auditoría semántica completa; no razonador OWL ni validación SHACL |
| IA | REST separados para inferencia, actas, publicación y transcripción | Cola, cancelación, despliegue multiusuario y empaquetado portátil completo |
| Audio | Original persistente, SHA-256, intentos, selector y reintento REST con dos motores | Historial navegable, metadatos completos por intento, retención/cuotas y recuperación de intentos interrumpidos |
| Motores | faster-whisper y whisper.cpp base; intento GPU y alternativa CPU en cpp | Traducción intercambiable, selector libre de modelo/dispositivo, benchmark y multiGPU/NVLink |
| Voz | Dictado de escritorio y actas desde audio | Dictado navegador/móvil/Mac, diarización y transcripción fonética IPA |
| Publicación | Vista previa y publicación explícita en wiki Redmine | Adaptadores de publicación estructurada para todos los gestores |
| Identidad | Sesiones locales y validación de usuario contra Redmine | LDAP/SSO y delegación de identidad para cada escritura |

Dos RTX 3090 fueron detectadas en pruebas anteriores. No se suman automáticamente
sus memorias; NVLink no está validado ni implementado como distribución de modelos.

## GitHub comprobado

- Repositorio: https://github.com/fpgulias/cosmoSys_deploy
- Desarrollo: `development/standalone-services`; remoto verificado en `171234a`
  antes de esta actualización documental. El propio commit de este informe añade
  la documentación posterior. `main` conserva el proyecto de despliegue original.
- Un repositorio contiene clientes, servicios y plugin; no existen repositorios
  separados para cada aplicación dentro de esta entrega.
- PR upstream #13: https://github.com/cosmoBots/cosmoSys_deploy/pull/13
  abierta, borrador, sin fusionar; cabeza `5a2d2a8` de
  `feature/semantic-exchange-review`. La API indicó `mergeable=false`; falta
  analizar y resolver la incompatibilidad antes de proponer su integración.
- Subir desarrollo no actualiza esa PR. No se ha realizado merge en cosmoBots.
- En un repositorio público, las ramas y los borradores también son visibles.
  Las adiciones se atribuyen al proyecto de fpgulias con asistencia de Codex,
  preservando autoría y licencia GPL-3.0 anteriores.

## Instalación local comprobada

Raíz de aplicaciones: `Documents/Codex`, fuera del checkout de desarrollo.

| Servicio | Puerto | Observación de esta auditoría |
|---|---:|---|
| cosmoSys | 3080 | HTTP 200; escucha en todas las interfaces |
| CGRol | 3090 | HTTP 200; escucha en todas las interfaces |
| Historias | 3110 | Sin proceso escuchando; no implica pérdida de datos |
| Académico | 3120 | HTTP 200 en loopback |
| Inferencia | 3130 | Puerto loopback escuchando |
| Actas | 3131 | Puerto loopback escuchando |
| Publicación | 3132 | Puerto loopback escuchando |
| Transcripción | 3133 | Puerto loopback escuchando |
| Ollama | 11434 | Puerto loopback escuchando |

Un puerto abierto o HTTP 200 no acredita una transcripción ni el funcionamiento
completo de un proveedor. Las pruebas reales de dos motores están documentadas en
transcription-engines.md. No se ha repetido inferencia durante esta auditoría.

Comparación SHA-256: código Python/HTML/JS/CSS de Gestores e IA-local coincide con
el checkout (excluidas pruebas); módulos Python de services también coinciden.
El codec bridge.py coincide. El escritorio Intercambio-textos conserva un app.py
anterior con configuración de cuentas específica del equipo y no tiene
rest_adapter.py. Debe actualizarse conjuntamente con su lanzador/configuración y
probar autenticación antes de declararlo equivalente a la versión publicada.
No se ha sobrescrito durante esta revisión.

Los servicios Python son procesos iniciados por lanzadores, no servicios Windows
con arranque automático garantizado. No se ha auditado en esta revisión toda la VM,
sus imágenes Docker, controladores o instalación de Windows antiguo/plotter.

## Recuperación y validación

Hay una copia Git bundle del 24/10 anterior a los últimos cambios, y una copia
privada del 25/10 de fuentes/importación, universo lógico, documento y SQLite.
No equivalen a una copia completa actual de VM/PostgreSQL, adjuntos, audios y claves.
La clave de firma del intercambio es necesaria para reimportar documentos antiguos;
restaurar la base permite generar exportaciones nuevas, pero no sustituye esa clave.
No consta una restauración integral ensayada ni backup periódico completo de todos
los módulos. No subir secretos sin un procedimiento de copia privada adecuado.

Últimas validaciones registradas antes de esta revisión: 20 pruebas de servicios,
6 de clientes IA, 4 de gestores y 9 de intercambio; pruebas reales de transcripción
y verificación de exportación/reimportación del documento importado. Son evidencia
histórica, no pruebas repetidas hoy. Esta revisión modifica documentación y verifica
remoto, respuestas HTTP, puertos y coincidencia de archivos; no certifica producción.

## Siguientes cierres verificables

1. Unificar instalación y lanzador del intercambio, comprobar historias y registrar
   un manifiesto de versiones reproducible de todos los componentes locales.
2. Completar copia privada actual y ensayar restauración de servicios, documentos,
   audio y claves; incluir el Git reciente en el siguiente bundle.
3. Resolver integración de ramas con upstream sin mezclar publicación con aprobación.
4. Completar historial/metadatos del audio y configuración de motores; mantener
   traducción separada de reconocimiento de voz.
5. Completar APA7 y verificarlo visualmente con una plantilla académica acordada.
6. Planificar despliegue semántico con copia y validación; no confundir relaciones
   descriptivas importadas con validación ontológica activa.

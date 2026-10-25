# Exportación académica: primera entrega experimental

El gestor académico incorpora una descarga independiente del Word estándar:
`GET /export?work=<id>&profile=academic-base`. Requiere la sesión habitual y toma
el trabajo guardado. Aplica márgenes de 2,54 cm, Times New Roman 12, interlineado
doble sin espacio adicional entre párrafos y sangría inicial de 1,27 cm al estilo
Normal. Conserva los controles de contenido y manifiesto del intercambio reversible.
No utiliza IA ni modifica contenido o referencias.

Actualización 26/10/2026: Heading1 centrado/negrita, Heading2 a la izquierda/negrita
y Heading3 a la izquierda/negrita/cursiva, todos sin sangría inicial. Reaplicar el
perfil produce los mismos bytes, sin duplicar propiedades. No se reescriben los
títulos ni se altera su capitalización. Los niveles 4 y 5 integrados en el párrafo
siguen pendientes, igual que paginación y portada. No se presenta como APA7 completo.
Referencia: https://apastyle.apa.org/style-grammar-guidelines/paper-format/headings

No es un exportador APA7 completo. Pendientes: portada y sus metadatos, números de
página, tratamiento de los cinco niveles APA, citas en bloque, tablas, figuras,
referencias con sangría francesa y comprobación de citas/referencias. Los títulos
jerárquicos de cosmoSys se conservan sin afirmar conformidad APA completa. Tampoco
aplica plantillas institucionales de TFG, TFM o tesis. Las notas bibliográficas del
gestor no se insertan automáticamente.

Pruebas: salida binaria determinista, márgenes/interlineado XML y reimportación sin
cambios falsos. Falta revisión visual en Word/LibreOffice; no desplegar como formato
final de entrega académica. La interfaz lo identifica como experimental.

Fuentes oficiales consultadas el 24/10/2026:
- https://apastyle.apa.org/style-grammar-guidelines/paper-format/margins
- https://apastyle.apa.org/style-grammar-guidelines/paper-format/line-spacing
- https://www.apa.org/ed/precollege/psn/2020/09/apa-style-student-papers

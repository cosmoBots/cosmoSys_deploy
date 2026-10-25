# Lanzador de clientes locales

`clients/launch.py` carga explícitamente un JSON privado con un objeto `environment`
de cadenas y ejecuta `intercambio`, `historias` o `academico`. Mantener el lanzador
junto a las carpetas Gestores e Intercambio-textos. Usa el mismo intérprete Python.

Ejemplo: `python clients/launch.py historias --config /private/launcher.json`.
Los gestores admiten `--serve` para iniciar únicamente el servidor sin abrir navegador.
En Windows, los accesos directos pueden usar pythonw.exe para no abrir consola.

Configurar COSMOSYS_URL, COSMOSYS_LOGIN, COSMOSYS_PASSWORD_FILE y
COSMOSYS_ALLOWED_LOGINS; para intercambio con CGRol, también CGROL_URL,
CGROL_LOGIN y CGROL_PASSWORD_FILE. Los valores *_PASSWORD_FILE son rutas a archivos
privados, no contraseñas publicadas. No añadir el JSON privado a Git.
El lanzador acepta el objeto environment de la configuración existente de servicios
IA, pero no inicia ni requiere esos servicios para abrir los gestores.

Antes de actualizar guardar copia de app.py, adaptadores, lanzador y accesos
directos. Conservar bases de datos, claves de firma y configuración. Reiniciar
ventanas de escritorio abiertas para cargar el código nuevo. Este lanzador no
actualiza automáticamente procesos web que ya estaban ejecutándose.

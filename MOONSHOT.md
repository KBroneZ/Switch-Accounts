# MOONSHOT — de "abrir otra pestaña" a **Fleet Control**

> Pregunta: ¿cuál sería el moonshot absoluto para Switch-Accounts, con recursos ilimitados y 12 meses?

## La visión

Hoy `switch-account` es un lanzador: lee el `/usage` de cada cuenta, elige una y abre una pestaña.
No sabe qué pasa después. Si la cuenta B lleva días con el login caducado, la herramienta dice
"no Current session line" y nadie entiende por qué.

El moonshot es una **cabina de mando para todas tus cuentas de Claude Code**: un panel vivo, al
estilo de Flightdeck, que responde en menos de 2 segundos a tres preguntas:

1. **¿Qué está haciendo cada cuenta ahora mismo?** Cada sesión abierta, en cualquier cuenta, con
   su carpeta, rama, modelo, estado (pensando, ejecutando una herramienta, esperando permiso,
   inactiva), contexto usado y coste.
2. **¿Cuánto le queda a cada cuenta y cuándo se recupera?** Uso de 5 h y semanal contra tus
   topes, hora de reinicio, plan, login y su caducidad, y una predicción: "A llega a su tope a
   las 18:40 a este ritmo".
3. **¿Dónde abro la siguiente sesión?** Un botón que abre la sesión bien configurada en la
   cuenta que tiene ese papel, sin teclear flags.

Flightdeck vigila **una** sesión. Fleet Control vigila **la flota**.

## Métricas norte

| Métrica | Hoy | Meta a 12 meses |
|---------|-----|-----------------|
| Tiempo para saber qué hace cada cuenta | abrir cada pestaña | < 2 s, un vistazo al panel |
| Sorpresas "sin tokens" o "login caducado" | frecuentes, diagnóstico confuso | 0: aviso antes de que ocurra |
| Tiempo de `-List` con 2 cuentas | ~7 s, secuencial | < 2 s (paralelo + caché) |
| Pasos para abrir una sesión bien configurada | skill + preguntas | 1 clic en el panel |

## Pilares

1. **Salud veraz de la cuenta.** `claude auth status --json` (login, plan, caducidad) antes que
   `/usage`; cada estado con su causa y su arreglo exacto ("B: login caducado → ejecuta …").
2. **Bus de flota local.** Cada sesión, de cualquier cuenta, publica un latido en
   `~/.claude-switch/live/`: cuenta, carpeta, modelo, estado, herramienta actual, contexto,
   coste. Solo archivos locales, con caducidad. Nada sale de la máquina.
3. **Panel Fleet** (mod de Claude Code). Tarjetas por cuenta con medidores y marcas de tope,
   y debajo las sesiones vivas de esa cuenta. Comandos `/fleet`, `/fleet refresh`.
4. **Predicción.** Muestras de uso cada pocos minutos → ritmo de consumo → hora estimada del tope
   y "¿me da para una tarea de 2 h en A?".
5. **Centro de mando.** Abrir sesiones desde el panel, ver el pipeline (A implementa, B revisa)
   como carriles, la cola de tareas y el estado de cada PR.
6. **Historia y distribución.** Informe semanal por cuenta y proyecto; plugin de marketplace que
   instala skill + mod + módulo de una vez; lanzadores para tmux/iTerm además de Windows Terminal.

## Barandillas (no negociables)

- Solo cuentas propias. **Nunca rotar cuentas para saltarse un límite**: cada cuenta tiene su
  papel; si llega a su tope, su papel espera. El panel informa; no "mueve trabajo" a otra cuenta.
- Uso desconocido nunca cuenta como 0 %.
- No se leen ni se copian credenciales. Del `auth status` solo se guardan login, método, plan y
  caducidad; nunca email, organización ni ids.
- Todo local. Ni red propia, ni telemetría.
- Nunca fusionar PRs, forzar pushes ni saltarse permisos.

## Hoja de ruta: 6 fases

### Fase 1 — Cimientos fiables (mes 1)
- Diagnóstico de login con `claude auth status --json`: "login caducado" en vez de "no Current
  session line"; no se llama a `/usage` si no hay login (ahorra ~6 s).
- Detectar la salida de `/cost` ("Total cost:") que da `/usage` sin suscripción.
- Lectura de cuentas en paralelo.
- Instantánea `~/.claude-switch/status.json` (contrato JSON v1) que leen el panel y otros.
- `-List` muestra plan, login y caducidad.

### Fase 2 — Bus de flota (mes 2)
- Hooks del mod que escriben `~/.claude-switch/live/<sesión>.json` en cada inicio de turno,
  herramienta y fin de turno (con límite de frecuencia), y lo marcan al cerrar la sesión.
- Esquema v1 versionado; los latidos de más de 15 min se consideran muertos.

### Fase 3 — Panel Fleet v1 (meses 3–4)
- Panel acoplado al lado del chat, como Flightdeck: tarjetas de cuenta con medidores 5 h y
  semanal, marca del tope, reinicio, login; sesiones vivas agrupadas por cuenta.
- Línea de estado compacta (`A 34% · B login!`) y avisos (toasts) cuando algo cambia.
- Refresco del uso cada 5 min en segundo plano (`/usage` no gasta tokens).

### Fase 4 — Predicción y alertas (meses 5–6)
- Historial `usage-history.jsonl`; ritmo por cuenta; hora estimada de tope.
- Avisos: tope cerca, reinicio ocurrido, login caduca en < 3 días.

### Fase 5 — Centro de mando (meses 7–9)
- Botones "abrir sesión aquí en A/B" desde el panel (mismo motor `Open-ClaudeSession`).
- Carriles del pipeline A/B, cola de tareas y estado de PRs.

### Fase 6 — Historia y distribución (meses 10–12)
- Informe semanal; uso por proyecto.
- Plugin de marketplace (skill + mod + módulo), lanzadores multiplataforma.

## Estado

| Fase | Estado |
|------|--------|
| 1 | hecha (0.3.0) |
| 2 | hecha: latidos en `live/` (v1, sin esperas de permiso aún) |
| 3 | hecha: panel `/fleet` v1 (falta: avisos de login a 3 días como toast) |
| 4 | hecha: historial de 8 días, ritmo y hora de tope por ventana, avisos únicos |
| 5 | hecha: botón abrir sesión por cuenta, caja PIPELINE |
| 6 | hecha en parte: informe diario y marketplace del plugin. Falta: lanzadores tmux/iTerm (Open-ClaudeSession solo conoce Windows Terminal) |

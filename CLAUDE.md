# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Qué es este repo

FlowSync: proyecto de práctica del curso (gestión de tareas en equipo). Monorepo sin workspaces ni `package.json` raíz — **los comandos de Node se ejecutan desde `backend/` o desde `frontend/`**; los de Docker y los atajos del `Makefile`, desde la raíz.

- `backend/` — API AdonisJS 7 + Lucid 22 + PostgreSQL 17 (Docker), escucha en `http://localhost:3333`
- `frontend/` — React 19 + Vite 8, escucha en `http://localhost:5173`

La rama `s1/start` es el punto de partida de los alumnos; `main` es la base del repo cliente.

## Comandos

### Bases de datos (desde la raíz)

PostgreSQL 17 (`pgvector/pgvector:pg17`, la imagen de producción) en Docker, definido en `compose.yaml`: servicio `db` (desarrollo, puerto **54410**, con volumen) y `db-test` (pruebas, puerto **54411**, `tmpfs` y sin volumen: se vacía al pararlo). Los dos tienen healthcheck por TCP y `make db-up` espera a que estén sanos. No uses el 5432 ni pongas `version:` en el fichero.

```bash
make db-up        # levanta db y db-test y espera a los healthchecks
make migrate      # migra LAS DOS (la de pruebas con NODE_ENV=test)
make seed         # 5 personas y 40 tareas de desarrollo (idempotente, solo en development)
make db-readonly  # rol flowsync_ro (solo SELECT, también en tablas futuras) en la base de desarrollo; contraseña en DB_RO_PASSWORD
make copia-produccion  # carga SEUDONIMIZADA la copia de producción en desarrollo, sustituyendo sus datos (solo la lanza una persona)
make test         # db-up + migrate + npm test
make db-down      # para las dos; la de desarrollo conserva el volumen
```

El SQL del rol de solo lectura está en `backend/database/readonly-role.sql`. Ojo al probarlo: dentro del contenedor la imagen tiene `trust` para `127.0.0.1`, así que una conexión por TCP desde dentro no comprueba la contraseña; hay que conectar desde el host por el puerto 54410. `DB_RO_PASSWORD` la lee solo el Makefile, por eso no está en el schema de `start/env.ts`. Ese rol puede leer **todo** lo de la base, incluidos los hashes de `users` y `auth_access_tokens`: no restaures en ella datos reales (ver `docs/incidencias/INC-0412-tareas-que-no-salen.md`).

Para consultar el esquema real hay un servidor MCP `dbhub` (DBHub 1.4.0 de Bytebase) en `.mcp.json`, configurado en `backend/database/dbhub.toml`: se conecta como `flowsync_ro`, con `execute_sql` en `readonly = true` y `search_objects` declarada (al listar alguna herramienta, DBHub desactiva las demás). La contraseña no está en ningún fichero: el lanzador de `.mcp.json` la lee de `backend/.env` y la pasa solo al proceso de DBHub, que sustituye `${DB_RO_PASSWORD}`. Necesita `make db-up` y `make db-readonly` hechos antes, y Node >= 22.5.

`make copia-produccion` (INC-0412) restaura `backups/produccion-2026-10-02.dump` en `flowsync_staging`, una base intermedia del servicio `db` cerrada a `flowsync_ro`, aplica `backend/database/seudonimizar.sql`, pasa el resultado a desarrollo y borra la intermedia (todo en `backend/database/copia-produccion.sh`). **`backups/` está vetada a Claude** (`permissions.deny` en `.claude/settings.json`): la copia lleva datos personales reales, no se abre ni se restaura desde aquí. `seudonimizar.sql` es una lista blanca (construye el esquema `salida` nombrando las columnas que viajan); si cambia el esquema de `users` o `tasks`, hay que revisarlo a la vez que la migración. El puerto de `db` solo escucha en `127.0.0.1` por esta razón.

La suite apunta a `db-test` por `backend/.env.test`, que AdonisJS carga solo con `NODE_ENV=test` y que pisa a `.env`. Como `db-test` es efímera, tras un `db-down` hay que volver a migrarla (`make migrate`).

### Backend (`cd backend`)

```bash
npm install
cp .env.example .env && node ace generate:key   # solo la primera vez
node ace migration:run                          # migra la base de desarrollo y regenera database/schema.ts
NODE_ENV=test node ace migration:run            # ídem contra la de pruebas
npm run dev                                     # node ace serve --hmr
npm test                                        # node ace test
npm run openapi:generate                        # escribe el documento OpenAPI en docs/api/openapi.json
npm run openapi:check                           # compara el versionado con el regenerado; sale 1 si difieren
npm run lint                                    # eslint
npm run format                                  # prettier --write
npm run typecheck                               # tsc --noEmit
```

Tests (Japa). Dos suites declaradas en `adonisrc.ts`: `unit` (`tests/unit/**/*.spec.ts`, timeout 2s) y `functional` (`tests/functional/**/*.spec.ts`, timeout 30s). Hoy solo hay tests **functional de `auth`** (`tests/functional/auth/`): registro, login, sesión e iniciales. **`tests/unit/` no existe**, y la capability `tasks` no tiene ni un test.

```bash
node ace test unit                    # una suite
node ace test --files=user            # filtrar por nombre de fichero
node ace test --tests="crea un user"  # filtrar por título de test
node ace test --groups=... --tags=... --failed --watch
node ace make:test --suite=functional # scaffolding de un fichero de test
```

Ojo con la BD en tests: `config/database.ts` define una única conexión `pg` y lo que cambia entre entornos son las variables `DB_*`. `.env.test` apunta a `db-test` (54411, base `flowsync_test`) y cambia `SESSION_DRIVER=memory`, así que las suites ya no tocan los datos de desarrollo. Dentro de la suite, el estado sí se filtra entre tests: si añades tests que escriben, aísla con los hooks de `testUtils.db()` (truncate / transacción global).

Otros comandos útiles: `node ace list:routes`, `node ace make:controller|model|migration|validator|transformer|service`, `node ace migration:fresh`, `node ace repl`.

### Frontend (`cd frontend`)

```bash
npm install
npm run dev
npm run build     # tsc -b && vite build (aquí se hace el typecheck)
npm run lint      # oxlint (NO eslint)
npm run format    # prettier --write .
```

No hay runner de tests instalado en el frontend.

## Arquitectura del backend

### El esquema se genera, no se escribe

`database/schema.ts` está **autogenerado** desde las migraciones (`schemaGeneration.enabled` en `config/database.ts`) y no debe editarse. Los modelos **no declaran columnas**: extienden la clase generada.

```ts
// app/models/user.ts
export default class User extends compose(UserSchema, withAuthFinder(hash)) { ... }
```

Flujo para cambiar el modelo de datos: crear migración → `node ace migration:run` (regenera `database/schema.ts`) → añadir al modelo solo relaciones, mixins, getters y lógica. Reglas de generación personalizadas en `database/schema_rules.ts`.

### Código generado versionado en `.adonisjs/`

`backend/.adonisjs/` está **commiteado** (no ignorado) para que un clon limpio compile antes de arrancar nada. Lo regeneran los hooks `indexEntities()` + `generateRegistry()` de `adonisrc.ts` al bootear:

- `.adonisjs/server/controllers.ts` — mapa de controladores. `start/routes.ts` los referencia vía `import { controllers } from '#generated/controllers'` y `[controllers.Profile, 'show']`, **no** con lazy imports de rutas.
- `.adonisjs/client/registry/` — registro Tuyau (rutas + tipos de request/response) pensado para consumo tipado desde el frontend. `tests/bootstrap.ts` lo engancha al `apiClient` de Japa, así que en tests functional las rutas y sus payloads están tipados.

Si tocas controladores o rutas y los tipos generados quedan obsoletos, arranca el dev server o corre los tests para regenerarlos, y commitea el diff.

### Toda respuesta pasa por `serialize()`

`providers/api_provider.ts` inyecta `ctx.serialize()` en cada `HttpContext` con un serializer que envuelve el payload en `{ data: ... }`. Convención en controladores:

```ts
async show({ auth, serialize }: HttpContext) {
  return serialize(UserTransformer.transform(auth.getUserOrFail()))
}
```

Usa siempre un transformer de `app/transformers/` (clases `BaseTransformer` con `toObject()` + `this.pick(...)`) en vez de devolver modelos crudos. Para respuestas sin envoltorio: `serialize.withoutWrapping(...)`.

### Auth

Dos guards en `config/auth.ts`; el **default es `api`** (access tokens opacos vía `DbAccessTokensProvider`), `web` (sesión) está configurado pero sin uso. En `start/kernel.ts` el `silent_auth_middleware` corre en todas las rutas; la protección real se aplica con `.use(middleware.auth())` sobre el grupo. `force_json_response_middleware` fuerza JSON en todo.

Rutas actuales (`start/routes.ts`), todas bajo `/api/v1`:

| Método | Ruta | Controlador | Auth |
|---|---|---|---|
| POST | `/api/v1/auth/signup` | `NewAccountController.store` | no |
| POST | `/api/v1/auth/login` | `AccessTokensController.store` | no |
| GET | `/api/v1/account/profile` | `ProfileController.show` | sí |
| POST | `/api/v1/account/logout` | `AccessTokensController.destroy` | sí |

### Datos de desarrollo (factories y seeder)

`database/factories/` (`UserFactory`, `TaskFactory`) y `database/seeders/main_seeder.ts`. Las factories cumplen por sí solas las reglas de negocio que el esquema no impone (estado entre los tres del dominio, título presentable, fecha de vencimiento opcional y rara por defecto, nombre obligatorio), y el seeder solo las compone. Las personas son cinco, con correo `nombre.apellido` en el dominio `DOMINIO_DEMO` y la contraseña `PASSWORD_DEMO`, ambos exportados de `user_factory.ts`. El seeder lleva `static environment = ['development']`, es idempotente y reparte las fechas de creación en los últimos 90 días contando desde el momento de lanzarlo.

### Validación

VineJS 4 en `app/validators/`, consumido con `request.validateUsing(validator)`. Nota de API: se usa `vine.create({...})` (no `vine.compile`), y hay reglas como `.sameAs('password')` y `.unique({ table, column })` sobre el schema. Los validadores comparten builders de campo (`email()`, `password()`) en vez de repetir reglas.

### Imports por subpath

`package.json` mapea `#controllers/*`, `#models/*`, `#validators/*`, `#transformers/*`, `#database/*`, `#generated/*`, `#start/*`, `#config/*`, `#tests/*`, etc. Úsalos siempre en lugar de rutas relativas. Nuevas variables de entorno: `node ace env:add` (las añade a `.env`, `.env.example` y al schema de `start/env.ts`, que valida al arrancar). `env:add` no sabe de secretos: `DB_PASSWORD` se declaró a mano como `Env.schema.secret()`, y en `config/database.ts` se pasa con `.release()`.

## Versiones por delante de la documentación conocida

El stack va deliberadamente en versiones muy recientes: **AdonisJS 7, Lucid 22, VineJS 4, Auth 10, TypeScript 6, React 19, Vite 8, oxlint**. Varias APIs difieren de las de versiones anteriores (esquema generado en vez de columnas en el modelo, registro de controladores generado, transformers/serializers, `vine.create`). Antes de asumir una firma por memoria o por docs de v6, comprueba los `.d.ts` reales en `backend/node_modules/@adonisjs/*/build/`.

## Frontend

El typecheck vive dentro de `npm run build`; el lint es **oxlint** (`.oxlintrc.json`), no eslint. El formateo es Prettier (`.prettierrc.json`: `semi: false`, `singleQuote: true`, para respetar el estilo ya existente); un hook `PostToolUse` en `.claude/settings.json` lo corre automáticamente sobre cada fichero de `frontend/` que Claude edite. No hay runner de tests instalado.

Stack: **Tailwind v4** (plugin de Vite, sin `tailwind.config.js`; los tokens viven en `src/index.css`), **shadcn/ui** (`components.json`, componentes generados en `src/components/ui/` — se traen con `npx shadcn@latest add <componente>` y no se editan a mano) y **react-router**. El alias `@/*` → `src/*` está declarado a la vez en `tsconfig.app.json` (sin `baseUrl`, deprecado en TS 6) y en `vite.config.ts`.

Organización de `src/`:

- `lib/api.ts` — único punto de contacto con el backend: envuelve `fetch`, desenvuelve el `{ data }` del serializer, adjunta el `Authorization: Bearer` y traduce los errores de VineJS/auth a `ApiError` con `message` ya en castellano y `fieldErrors` por campo. Toda llamada nueva a la API se añade aquí, no en los componentes.
- `auth/` — `auth-context.ts` (solo el contexto, sin componentes, para no romper `react/only-export-components`), `auth-provider.tsx` (token en `localStorage` bajo `flowsync.token`, rehidratado contra `GET /account/profile` al arrancar), `use-auth.ts` y `use-auth-form.ts`.
- `routes/` — `app-routes.tsx` más los guards `protected-route.tsx` y `public-only-route.tsx`.
- `pages/`, `components/` — pantallas y componentes propios.

La URL de la API sale de `VITE_API_URL` (ver `frontend/.env.example`); por defecto `http://localhost:3333`.

### De dónde sale una pieza de interfaz nueva

Antes de escribir un componente o un elemento de interfaz, se mira qué hay, en este orden, y se para en el primer paso que lo resuelva:

1. **El catálogo, `frontend/src/components/ui/`.** Se leen las variantes y tamaños que declara cada pieza (los `cva`, como `buttonVariants`) antes de decidir que no sirve: casi siempre lo que hace falta es una variante, un tamaño o un `className` sobre algo que ya existe.
2. **Los componentes propios, `frontend/src/components/`.** Si uno casi sirve, se adapta por props o por composición en vez de escribir otro parecido.
3. **Una primitiva de shadcn/ui que aún no esté instalada**, traída con el CLI como dice el Stack de arriba. Se revisa el diff antes de seguir: aquí el CLI no resuelve el alias `@/lib/utils` y ya ha llegado a importar `cn` de un paquete npm ajeno, que además instaló.
4. **Solo si nada de lo anterior sirve**, una pieza nueva en `frontend/src/components/` (nunca a mano en `ui/`), compuesta con lo que ya hay y con un comentario que diga qué se descartó del catálogo y por qué.

En los cuatro casos, ni duplicar ni inventar estilos: no se copian a mano las clases de una variante que ya existe, y los colores salen de los tokens de `src/index.css` por sus utilidades (`bg-primary`, `text-muted-foreground`, `border-border`…), nunca de un hexadecimal, un `rgb()`/`hsl()` ni una clase de paleta cruda como `bg-blue-600`. Si ningún token encaja, se dice antes de escribir nada: un color nuevo es un token nuevo, y esa decisión no se toma de pasada. El hook `PostToolUse` `.claude/hooks/aviso-colores-a-pelo.sh` avisa, sin bloquear, cuando un Write o un Edit mete uno de esos valores en `frontend/src/`; si la pieza tenía que haber salido del catálogo no lo puede ver ningún script, y por eso es esta regla.

## Reglas de proceso
- Convenciones de base de datos (única fuente, no se copian aquí): @docs/convenciones/base-de-datos.md
- Cualquier tarea de backend se hace con la skill `backend-feature` (`.claude/skills/backend-feature/SKILL.md`), sin que nadie tenga que pedirlo: plan por capas y parada para aprobarlo, tests de contrato con el subagente `test-writer`, rojo, tests congelados por su `shasum`, implementación con el subagente `implementer` hasta el verde, y cierre con `dbhub`, `openapi:check` y Postman.
- La rama es por unidad de trabajo, no por petición. Antes de tocar código, mira en qué rama estás: si ya es una rama de trabajo —cualquiera que no sea `main` ni una `sN/*`—, sigue en ella en vez de crear otra. Solo desde `main` o desde una `sN/*` se crea una nueva (`git checkout -b feat/<slug>`). Nunca commitear directo en `main` ni en una `sN/*`.
- El commit sí es por petición: al cerrar cada una, usar la skill `/commit`.
- Un cambio que toque rutas, controladores, validadores o transformers de una capability se cierra en el mismo commit con el documento OpenAPI y el README de esa capability al día. El documento se construye en cada petición y no hay fichero que generar, así que lo que se commitea es el diff regenerado de `.adonisjs/`; el README es `docs/capabilities/<nombre>/README.md`.
- `gh pr create` (con una descripción completa de los cambios en el cuerpo del PR) y el pase del subagente `adversarial-reviewer` sobre ese PR van **una sola vez, al terminar la unidad de trabajo**, no al cerrar cada petición. El review adversarial es lo último, antes de dar la unidad por terminada.
- Cuando abras el PR, no repitas ese resumen en el chat: la sesión se va a perder, el PR no. Responde solo con la URL del PR.
- Datos que no salen del proyecto: el hook `PreToolUse` `.claude/hooks/datos-que-no-salen.sh` revisa cada `git commit` (y lo que añade un `git add` en el mismo comando) y lo bloquea si entra alguna de estas tres cosas: (1) una clave o un token con forma reconocible (AWS, Anthropic, GitHub, Google, Slack, clave privada, `APP_KEY` con valor); (2) un correo cuyo dominio no sea `example.com`, `example.org`, `example.net` ni `github.com`; (3) un fichero `.env`. Cuando bloquea, **no se desactiva, no se salta y no se reescribe el comando para esquivarlo**: se sustituye el dato por uno inventado (correo en `example.com`, clave de mentira) o se saca el `.env` del índice, y se vuelve a intentar. Cada bloqueo añade una línea a `docs/seguridad/registro-de-bloqueos.md`, con la regla y el archivo pero nunca el valor. Ese registro se commitea con el resto del cambio: es la evidencia.
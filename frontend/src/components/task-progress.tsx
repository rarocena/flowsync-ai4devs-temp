import { useId } from 'react'

type TaskProgressProps = {
  /**
   * Cuántas tareas del equipo están hechas y cuántas hay en total, contando
   * también las que el filtro deja fuera, o `null` mientras no se sabe.
   */
  progress: { done: number; total: number } | null
  /** No se ha podido averiguar: se dice, en vez de pintar un 0 % que mentiría. */
  failed: boolean
}

const PERCENT = new Intl.NumberFormat('es', { style: 'percent' })

/**
 * Qué parte del trabajo del equipo está hecha.
 *
 * Mide sobre todas las tareas y no sobre las filas a la vista: la lista nunca
 * mezcla lo hecho con lo abierto —la vista por defecto deja fuera lo hecho y
 * cada filtro enseña un solo estado—, así que contar solo lo visible daría
 * siempre 0 % o 100 %. Por lo mismo no se mueve con el filtro: el filtro es
 * una lente sobre la lista, no sobre el trabajo del equipo.
 */
export function TaskProgress({ progress, failed }: TaskProgressProps) {
  const labelId = useId()

  const fraction =
    progress && progress.total > 0 ? progress.done / progress.total : 0
  // Hacia abajo: mientras quede una sola tarea abierta no se puede decir 100 %.
  const percent = Math.floor(fraction * 100)

  const summary = failed
    ? 'No se ha podido calcular'
    : progress === null
      ? 'Calculando…'
      : progress.total === 0
        ? 'Todavía no hay tareas'
        : `${progress.done} de ${progress.total} ${
            progress.total === 1 ? 'tarea hecha' : 'tareas hechas'
          } · ${PERCENT.format(percent / 100)}`

  return (
    <section
      className="bg-background rounded-lg border p-4"
      aria-labelledby={labelId}
    >
      <div className="mb-2 flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
        <h3 id={labelId} className="text-sm font-medium">
          Progreso del equipo
        </h3>
        <p className="text-muted-foreground text-sm tabular-nums">{summary}</p>
      </div>

      {/* Sin dato no hay barra: una vacía se leería como «nada hecho». */}
      {!failed && (
        <div
          role="progressbar"
          aria-labelledby={labelId}
          aria-valuemin={0}
          aria-valuemax={100}
          // Sin `aria-valuenow` la barra se anuncia como indeterminada, que es
          // justo lo que es mientras se calcula.
          aria-valuenow={progress ? percent : undefined}
          aria-valuetext={summary}
          className={`bg-primary/20 h-2 overflow-hidden rounded-full ${
            progress ? '' : 'animate-pulse'
          }`}
        >
          <div
            className="bg-primary h-full rounded-full transition-[width] motion-reduce:transition-none"
            style={{ width: `${fraction * 100}%` }}
          />
        </div>
      )}

      <p className="text-muted-foreground mt-2 text-xs">
        Cuenta todas las tareas del equipo, también las que el filtro deja
        fuera.
      </p>
    </section>
  )
}

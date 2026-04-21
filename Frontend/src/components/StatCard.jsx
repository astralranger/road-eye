export default function StatCard({ title, value, note, tone = "neutral" }) {
    return (
        <article className={`card tone-${tone}`}>
            <p className="card-title">{title}</p>
            <h3 className="card-value">{value}</h3>
            <p className="card-note">{note}</p>
        </article>
    );
}

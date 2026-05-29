/**
 * Pluggable Track D (MSA / Conga / DocuSign). Default stub advances status only;
 * replace with managed-package + REST implementation when ready.
 */
public interface IMsaTrack {
    /**
     * @return true when this invocation advanced or (re)started MSA work for the compliance row.
     */
    Boolean tryAdvance(Id complianceId);
}
# Pre-process to remove commas in parens, then format with fixed widths
sed 's/(\([^)]*\), \([^)]*\))/(\1 \2)/g' | \
awk -F',' '{
  printf "%-4s | %-35s | %-6s | %11s | %24s | %19s | %14s | %13s\n", 
  $1, $2, $3, $6, $7, $8, $9, $10;
  fflush()
}'   

exit
fixed widths
sed 's/(\([^)]*\), \([^)]*\))/(\1 \2)/g' | \
awk -F',' '{
  printf "%-4s | %-35s | %-6s | %13s | %11s | %11s | %24s | %19s | %14s | %13s | %15s | %20s | %13s | %14s\n", 
  $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14
}'   

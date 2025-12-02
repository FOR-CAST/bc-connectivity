OGMA <- sf::st_read(input_files[["OGMA"]])

plot(OGMA)

B <- st_distance(OGMA)
View(B)
avg_distances <- rowMeans(B)

c <- mean(avg_distances)

d <- c / 1000
hist(B)

H <- diag(B)
View(H)

u <- upper.tri(B)
View(u)

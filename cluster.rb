# frozen_string_literal: true

class Cluster < ActiveRecord::Base
  # Formula to calculate the distance between two coordinates in meters.
  # params: each param is an array of [lat,lng]
  def self.haversine_distance(coordinate_array_1, coordinate_array_2)
    rad_per_deg = Math::PI / 180
    # Earth radius in km
    rkm = 6371
    # Convert to m
    rm = rkm * 1000

    # Latitude & Longitude delta in Radians
    dlat_rad = (coordinate_array_2[0] - coordinate_array_1[0]) * rad_per_deg
    dlon_rad = (coordinate_array_2[1] - coordinate_array_1[1]) * rad_per_deg

    # Latitude & Longitude in Radians
    lat1_rad = coordinate_array_1[0] * rad_per_deg
    lat2_rad = coordinate_array_2[0] * rad_per_deg

    # Calculate distance in meters
    # WARNING: MATH
    a = Math.sin(dlat_rad / 2)**2 + Math.cos(lat1_rad) * Math.cos(lat2_rad) * Math.sin(dlon_rad / 2)**2
    c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))

    rm * c # Delta in meters
  end

  # Calculates the maximum distance, in meters, of any point in point_array vs. center_point
  # Points are in form [lat,lng]
  def self.calculate_distance_to_farthest_point(point_array, center_point)
    distances = []
    point_array.each do |point|
      distances << Cluster.haversine_distance(point, center_point)
    end
    return distances.max
  end

  # Defines the radius of a cluster as the distance to the furthest point in that cluster
  def self.calculate_radius_of_cluster(point_array, center_point)
    return calculate_distance_to_farthest_point(point_array, center_point)
  end

  # Takes in an array of points & calculates the *AVERAGE* center. Points are an array of [lat,lng]
  # Note that it calcs the average center, not the geographic center.
  def self.calculate_center_of_cluster(point_array)
    x = []
    y = []
    z = []
    point_array.each_with_index do |point, i|
      # Convert from Deg to Rad
      lat = point[0].to_f * Math::PI / 180
      lng = point[1].to_f * Math::PI / 180

      # Convert to Cartesian coordinates
      x[i] = Math.cos(lat) * Math.cos(lng)
      y[i] = Math.cos(lat) * Math.sin(lng)
      z[i] = Math.sin(lat)
    end

    # Compute average Cartesian coordinates
    num_points = point_array.length
    x = x.inject(0, :+) / num_points
    y = y.inject(0, :+) / num_points
    z = z.inject(0, :+) / num_points

    # Convert average Cartesian coordinates to latitude and longitude
    # WARNING: MATH
    lng = Math.atan2(y, x)
    hyp = Math.sqrt(x * x + y * y)
    lat = Math.atan2(z, hyp)

    # Convert latitude & longitude to Deg from Rad
    lat = lat * 180 / Math::PI
    lng = lng * 180 / Math::PI

    return [lat, lng]
  end

  # Calls the DBSCAN gem to run the DBSCAN algorithm
  def self.dbscan(data, epsilon, min_points)
    require 'dbscan'
    return DBSCAN(data, epsilon: epsilon, min_points: min_points, distance: :haversine_distance2)
  end

  #######################################################################################################################
  # Implements the DBSCAN clustering algorithm with a recursive heuristic. Epsilon represents the (arbitrary) distance
  # between points to be included in a cluster, and min_points is the minimum number of neighbor points before a cluster
  # will be made. i.e. min_points of 2 means a minimum cluster size of 3, since the central cluster point will have
  # 2 neighbors.
  # Algo will re-run with different parameters until each cluster has a radius < 90m by first dropping epsilon
  # then min_points.
  #######################################################################################################################

  # Clusters based off Venue data and saves them with cluster_type 0
  # If the recursion flag is set, it will re-run the clusters if they are too large
  def self.dbscan_venues(epsilon = 0.15, min_points = 7, data = [], recursion = true, iteration = 1)
    # Clear any current Venue clusters on first run
    Cluster.where(cluster_type: 0).destroy_all if iteration == 1

    # If first run, grab all relevant Venues
    venues = Venue.all if data.empty?

    # DBSCAN :)
    dbscan = Cluster.dbscan(data, epsilon, min_points)
    # Loop through *results*
    dbscan.results.each_with_index do |cluster, i|
      if i == 0 && !dbscan.clusters[-1].empty?
        # The [-1] cluster is full of outliers. This normally gets passed as the first element of the results array & is skipped.
        # BUT if there are no outliers, then the first element of the results array is a real cluster.
        # Therefore, skip the first element of the results array ONLY if the [-1] cluster ISN'T empty.
      else
        # Loop through each cluster's points
        cluster.each do |pointarray|
          if pointarray.is_a?(Array)
            # Calc radius & center of cluster
            center = Cluster.calculate_center_of_cluster(pointarray)
            radius = Cluster.calculate_radius_of_cluster(pointarray, center)
            if recursion
              # Heuristic - checks if radius is > 900km & re-runs ONLY this cluster's points.
              if radius > 900 && (epsilon > 0 && min_points > 0)
                done = Cluster.dbscan_venues(epsilon - 0.025, min_points - 1, pointarray, recursion, iteration + 1)
              elsif radius > 900 && (epsilon == 0 && min_points > 0)
                done = Cluster.dbscan_venues(0.3, min_points - 1, pointarray, recursion, iteration + 1)
              elsif radius > 900 && (epsilon == 0 && min_points == 0)
                # Can't create a cluster - return false.
                return false
              elsif radius <= 900 && radius >= 125
                # Add cluster to DB if radius is in the right size.
                ac = Cluster.create(lat: center[0], lng: center[1], radius: radius, cluster_type: 0)
              end
            else
              ac = Cluster.create(lat: center[0], lng: center[1], radius: radius, cluster_type: 0)
            end
          end
        end
      end
    end

    # It worked!
    return true
  end

  # Generates clusters that don't intersect with existing clusters
  # These clusters are added only if they don't overlap with any existing clusters
  # Same parameters as dbscan_venues
  # Saved as cluster_type 1
  def self.dbscan_non_intersecting(epsilon = 0.3, min_points = 2, data = [], recursion = true, iteration = 1)
    # Clear any current non-intersecting clusters
    Cluster.where(cluster_type: 1).destroy_all if iteration == 1

    existing_clusters = Cluster.where(cluster_type: 0)

    # Replace with whatever your data is
    venues = Venue.all if data.empty?

    # DBSCAN :)
    dbscan = Cluster.dbscan(data, epsilon, min_points)

    # Loop through *results*
    dbscan.results.each_with_index do |cluster, i|
      if i == 0 && !dbscan.clusters[-1].empty?
        # The [-1] cluster is full of outliers. This normally gets passed as the first element of the results array & is skipped.
        # BUT if there are no outliers, then the first element of the results array is a real cluster.
        # Therefore, skip the first element of the results array ONLY if the [-1] cluster ISN'T empty.
      else
        cluster.each do |pointarray|
          if pointarray.is_a?(Array)
            # Calc center of cluster & radius to further point
            center = Cluster.calculate_center_of_cluster(pointarray)
            radius = Cluster.calculate_radius_of_cluster(pointarray, center)
            if recursion
              # Heuristic - checks if radius is > 900km & re-runs.
              if radius > 900 && (epsilon > 0 && min_points > 0)
                Cluster.dbscan_non_intersecting(epsilon - 0.1, min_points, pointarray, recursion, iteration + 1)
                # Will break if function successfully runs & returns true
              elsif radius > 900 && (epsilon == 0 && min_points > 0)
                Cluster.dbscan_non_intersecting(0.3, min_points - 1, pointarray, recursion, iteration + 1)
              elsif radius > 900 && (epsilon == 0 && min_points == 0)
                return false
              elsif radius <= 900 && radius >= 125
                # Add cluster to DB only if this cluster doesn't intersect any existing clusters
                flag = true
                existing_clusters = Cluster.where(cluster_type: [0, 1])
                existing_clusters.each do |accom|
                  distance = Cluster.haversine_distance([accom.lat, accom.lng], [center[0], center[1]])
                  flag = false if distance < 0.9 * (accom.radius + radius)
                end
                if flag and radius > 125
                  ac = Cluster.create(lat: center[0], lng: center[1], radius: radius, cluster_type: 1)
                end
              end
            else
              # Add cluster to DB only if this cluster doesn't intersect any existing clusters
              flag = true
              existing_clusters = Cluster.where(cluster_type: [0, 1])
              existing_clusters.each do |accom|
                distance = Cluster.haversine_distance([accom.lat, accom.lng], [center[0], center[1]])
                flag = false if distance < 0.9 * (accom.radius + radius)
              end
              if flag and radius > 125
                ac = Cluster.create(lat: center[0], lng: center[1], radius: radius, cluster_type: 1)
              end
            end
          end
        end
      end
    end

    return true
  end

  # Takes cluster types 0 & 1 and clusters THOSE!
  # Used to merge very close clusters
  # Saved as cluster_type 2
  def self.dbscan_clusters(epsilon = 0.3, min_points = 1, delete_existing = false, delete_original = true)
    # Delete all current clustered clusters
    Cluster.where(cluster_type: 2).destroy_all unless delete_existing

    # Grab clusters
    clusters = Cluster.where(cluster_type: [0, 1, 2])
    data = clusters.map {|cluster| [cluster[:lat], cluster[:lng]] }

    dbscan = Cluster.dbscan(data, epsilon, min_points)

    # Loop through *results*
    dbscan.results.each_with_index do |cluster_result, i|
      if i == 0 && !dbscan.clusters[-1].empty?
        # The [-1] cluster is full of outliers. This normally gets passed as the first element of the results array & is skipped.
        # BUT if there are no outliers, then the first element of the results array is a real cluster.
        # Therefore, skip the first element of the results array ONLY if the [-1] cluster ISN'T empty.
      else
        cluster_result.each do |pointarray|
          if pointarray.is_a?(Array)
            # Calc center of cluster & radius to further point
            center = Cluster.calculate_center_of_cluster(pointarray)
            radius = Cluster.calculate_radius_of_cluster(pointarray, center)
            # Add cluster to DB
            Cluster.create(lat: center[0], lng: center[1], radius: radius, cluster_type: 2)

            # Delete the original clusters that created the new cluster if flagged
            pointarray.each do |point|
              clusters.where(lat: point[0].to_f, lng: point[1].to_f).destroy_all if delete_original
            end
          end
        end
      end
    end
  end
end
